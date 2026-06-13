# notify-discord.ps1 -- pings Discord when Claude Code is waiting for you, with a
# rich embed showing OFFICIAL usage (the same /api/oauth/usage endpoint /usage uses).
# Cross-platform: runs under Windows PowerShell 5.1 (Windows) and pwsh 7+ (macOS/Linux).
# Usage (from a hook): notify-discord.ps1 <Stop|Notification> [discord_user_id]
# Reads the hook's JSON payload on stdin.
param(
    [ValidateSet('Stop', 'Notification')]
    [string]$Event = 'Stop',
    [string]$UserId = ''
)

$ErrorActionPreference = 'Stop'

# (stdin is read as UTF-8 explicitly below, where $raw is assigned)

# Portable home -> ~/.claude (works on Windows, macOS, Linux).
$base = if ($HOME) { "$HOME" } else { "$env:USERPROFILE" }
$claudeDir = Join-Path $base '.claude'

# Whether the per-turn "this prompt" token count includes discounted cache reads.
$IncludeCacheReads = $false

$webhookFile = Join-Path $claudeDir 'discord_webhook.txt'
if (-not (Test-Path $webhookFile)) { exit 0 }
$webhookUrl = (Get-Content $webhookFile -Raw).Trim()
if (-not $webhookUrl) { exit 0 }

# Read the hook payload from stdin as UTF-8. Reliable on Windows PowerShell 5.1
# AND pwsh 7+. Do NOT use ($input | Out-String): on PS 5.1 it decodes stdin in
# the legacy OEM codepage, garbling em-dashes/accents/emoji (an em-dash becomes
# three junk characters). [Console]::InputEncoding is applied too late to fix it.
$raw = ''
try {
    $__stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding $false))
    $raw = $__stdin.ReadToEnd(); $__stdin.Dispose()
} catch { $raw = '' }
$projectName = Split-Path -Leaf (Get-Location)
$detail = ''
$transcriptPath = ''
$cwd = ''
$notificationType = ''
if ($raw) {
    try {
        $payload = $raw | ConvertFrom-Json
        if ($payload.message)           { $detail = "$($payload.message)" }
        if ($payload.cwd)               { $projectName = Split-Path -Leaf $payload.cwd; $cwd = $payload.cwd }
        if ($payload.transcript_path)   { $transcriptPath = $payload.transcript_path }
        if ($payload.notification_type) { $notificationType = "$($payload.notification_type)" }
    } catch { }
}

# Ping ONLY when Claude needs you. For the Notification hook the authoritative
# signal is notification_type (do NOT match on $detail text -- it is dynamic /
# localized). Allowed: tool-permission prompts (incl. AskUserQuestion and
# plan-mode, which surface as permission_prompt), MCP elicitation dialogs, and
# idle_prompt -- the ~60s "waiting for your input" signal that fires when Claude
# is finished/stuck and it's your turn to speak. Skipped (informational):
# auth_success, elicitation_complete/response, computer_use_*, push_notification.
# (For hard-blocks-only, drop 'idle_prompt' here AND from the settings matcher.)
# The Stop hook is not wired (turn-end != needs-input); defense-in-depth behind
# the settings matcher.
$needsInput = @('permission_prompt', 'worker_permission_prompt', 'idle_prompt', 'elicitation_dialog', 'elicitation_url_dialog')
if ($Event -eq 'Notification' -and $notificationType -and ($needsInput -notcontains $notificationType)) { exit 0 }

# --- helpers ----------------------------------------------------------------
function Get-UsageTokens($u) {
    if (-not $u) { return 0L }
    $t = [int64]0
    if ($u.input_tokens)                { $t += [int64]$u.input_tokens }
    if ($u.output_tokens)               { $t += [int64]$u.output_tokens }
    if ($u.cache_creation_input_tokens) { $t += [int64]$u.cache_creation_input_tokens }
    if ($IncludeCacheReads -and $u.cache_read_input_tokens) { $t += [int64]$u.cache_read_input_tokens }
    return $t
}
function Format-Tokens([int64]$n) {
    if ($n -ge 1000000) { return ('{0:0.0}M' -f ($n / 1000000.0)) }
    if ($n -ge 1000)    { return ('{0:0.0}K' -f ($n / 1000.0)) }
    return "$n"
}
# 10-segment progress bar from code points (keeps this source ASCII).
function Usage-Bar([int]$pct) {
    $full = [char]0x25B0; $empty = [char]0x25B1
    $f = [int][math]::Max(0, [math]::Min(10, [math]::Round($pct / 10.0)))
    return (("$full" * $f) + ("$empty" * (10 - $f)))
}
function Reset-In([string]$iso) {
    if (-not $iso) { return '' }
    try {
        $rem = ([datetimeoffset]::Parse($iso)).UtcDateTime - (Get-Date).ToUniversalTime()
        if ($rem.TotalSeconds -lt 0) { return 'now' }
        $h = [int][math]::Floor($rem.TotalHours)
        if ($h -gt 0) { return "${h}h $($rem.Minutes)m" } else { return "$($rem.Minutes)m" }
    } catch { return '' }
}
# Official usage from the same endpoint /usage calls, using the locally stored
# OAuth token. Linux/Windows: ~/.claude/.credentials.json. macOS: Keychain.
# Goes only to api.anthropic.com. Returns $null on any failure -> graceful skip.
function Get-RealUsage {
    try {
        $oauth = $null
        $credFile = Join-Path $claudeDir '.credentials.json'
        if (Test-Path $credFile) {
            $oauth = (Get-Content $credFile -Raw | ConvertFrom-Json).claudeAiOauth
        } elseif ($IsMacOS) {
            # macOS stores credentials in the login Keychain, not a file.
            # (Verify the service name on the Mac: `security find-generic-password -s "Claude Code-credentials" -w`)
            $json = & security find-generic-password -s 'Claude Code-credentials' -w 2>$null
            if ($json) { $oauth = ($json | ConvertFrom-Json).claudeAiOauth }
        }
        if (-not $oauth -or -not $oauth.accessToken) { return $null }
        $h = @{
            'Authorization'     = "Bearer $($oauth.accessToken)"
            'anthropic-beta'    = 'oauth-2025-04-20'
            'anthropic-version' = '2023-06-01'
            'User-Agent'        = 'claude-discord-usage-hook'
        }
        return Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $h -Method Get -TimeoutSec 8
    } catch { return $null }
}

# --- tokens used by the current prompt (since the last human message) -------
if (-not $transcriptPath -and $cwd) {
    $folder = Join-Path (Join-Path $claudeDir 'projects') ($cwd -replace '[:\\/]', '-')
    if (Test-Path $folder) {
        $newest = Get-ChildItem (Join-Path $folder '*.jsonl') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest) { $transcriptPath = $newest.FullName }
    }
}
$promptTokens = [int64]0
if ($transcriptPath -and (Test-Path $transcriptPath)) {
    try {
        $lines = Get-Content $transcriptPath
        $lastHuman = -1; $assist = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $ln = $lines[$i]
            if ($ln -match '"role":"user"') {
                try {
                    $o = $ln | ConvertFrom-Json
                    if ($o.type -eq 'user') {
                        $c = $o.message.content; $isHuman = $false
                        if ($c -is [string]) { $isHuman = $true }
                        elseif ($c) { foreach ($b in $c) { if ($b.type -eq 'text') { $isHuman = $true; break } } }
                        if ($isHuman) { $lastHuman = $i }
                    }
                } catch { }
            }
            elseif ($ln -match '"usage"') {
                try {
                    $o = $ln | ConvertFrom-Json
                    if ($o.type -eq 'assistant' -and $o.message.usage) {
                        $assist += [pscustomobject]@{ idx = $i; tok = (Get-UsageTokens $o.message.usage) }
                    }
                } catch { }
            }
        }
        foreach ($a in $assist) { if ($a.idx -gt $lastHuman) { $promptTokens += $a.tok } }
    } catch { }
}

# --- daily message counter (shared across events/projects). "#N". ------------
$countFile = Join-Path $claudeDir 'discord_notify_count.txt'
$today     = (Get-Date).ToString('yyyy-MM-dd')
$count = 1
if (Test-Path $countFile) {
    try {
        $parts = (Get-Content $countFile -Raw).Trim() -split '\s+'
        if ($parts.Count -ge 2 -and $parts[0] -eq $today) { $count = [int]$parts[1] + 1 }
    } catch { }
}
try { Set-Content -Path $countFile -Value "$today $count" -NoNewline -Encoding ascii } catch { }

# --- compose embed + send ---------------------------------------------------
$folderGlyph = [System.Char]::ConvertFromUtf32(0x1F4C1)
$usage = Get-RealUsage

if ($Event -eq 'Notification') {
    $glyph = [System.Char]::ConvertFromUtf32(0x1F514); $color = 15844367   # bell / amber
    if ($notificationType -like '*permission_prompt') { $title = "$glyph  Needs your permission" }
    else { $title = "$glyph  Needs your input" }
    $desc  = if ($detail) { $detail } else { 'Claude is waiting for your input.' }
} else {
    $glyph = [System.Char]::ConvertFromUtf32(0x2705);  $color = 3066993    # check / green
    $title = "$glyph  Turn complete"
    $desc  = 'Claude finished its turn -- waiting for your reply.'
}

$fields = @( @{ name = 'This prompt'; value = "$(Format-Tokens $promptTokens) tok"; inline = $true } )

if ($usage) {
    $p5 = [int][math]::Round([double]$usage.five_hour.utilization)
    $p7 = [int][math]::Round([double]$usage.seven_day.utilization)
    $desc += "`n`n$(Usage-Bar $p5)  **$p5%**  used (5h window)"
    $r5 = Reset-In $usage.five_hour.resets_at
    if ($r5) { $fields += @{ name = '5h resets in'; value = $r5; inline = $true } }
    $fields += @{ name = 'Weekly'; value = "$p7%"; inline = $true }
} else {
    $desc += "`n`n_live usage unavailable_"
}

$embed = @{
    color       = $color
    author      = @{ name = "$folderGlyph  $projectName" }
    title       = $title
    description = $desc
    fields      = $fields
    footer      = @{ text = "#$count  -  $((Get-Date).ToString('ddd MMM d, yyyy  h:mm tt'))" }
    timestamp   = (Get-Date).ToUniversalTime().ToString('o')
}

$body = @{ embeds = @($embed) }
if ($UserId) {
    $body['content'] = "<@$UserId>"
    $body['allowed_mentions'] = @{ users = @("$UserId") }
} else {
    $body['allowed_mentions'] = @{ parse = @() }
}

try {
    $json = $body | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Invoke-RestMethod -Uri $webhookUrl -Method Post -ContentType 'application/json; charset=utf-8' `
        -Body $bytes -TimeoutSec 10 | Out-Null
} catch { }
exit 0
