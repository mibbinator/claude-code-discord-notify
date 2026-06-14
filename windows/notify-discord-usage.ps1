# notify-discord-usage.ps1 -- posts a Discord embed every time OFFICIAL usage
# crosses to a new whole percent (~"every 1% used"), for the 5h + weekly windows.
# Silent by default; @-mentions the user when a crossing passes a milestone
# (25/50/80/90/100%) on EITHER window. When a window RESETS it posts a separate,
# highly-visible pinged message per window (5h and weekly independently), and
# distinguishes a normal scheduled rollover from a MANUAL reset Anthropic applies
# to everyone early (detected when usage drops while the prior reset time is still
# in the future). Reads the official /api/oauth/usage data (the same endpoint
# /usage uses), throttled to at most one API call per 5 min (cached), and
# persists the last posted % + reset times between runs.
# Cross-platform: Windows PowerShell 5.1 (Windows) and pwsh 7+ (macOS/Linux).
# Usage (from a hook): notify-discord-usage.ps1 [discord_user_id]
# Reads the hook's JSON payload on stdin (only used for the project name).
param(
    [string]$UserId = ''
)

$ErrorActionPreference = 'Stop'

# Portable home -> ~/.claude (works on Windows, macOS, Linux).
$base = if ($HOME) { "$HOME" } else { "$env:USERPROFILE" }
$claudeDir = Join-Path $base '.claude'

# Milestones that escalate a silent post to an @-mention ping (either window).
$Milestones = @(25, 50, 80, 90, 100)

$webhookFile = Join-Path $claudeDir 'discord_usage_webhook.txt'
if (-not (Test-Path $webhookFile)) { exit 0 }
$webhookUrl = (Get-Content $webhookFile -Raw).Trim()
if (-not $webhookUrl) { exit 0 }

# Read stdin (UTF-8) only to recover the project name. See notify-discord.ps1
# for why an explicit StreamReader is required on PS 5.1.
$raw = ''
try {
    $__stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding $false))
    $raw = $__stdin.ReadToEnd(); $__stdin.Dispose()
} catch { $raw = '' }
$projectName = Split-Path -Leaf (Get-Location)
if ($raw) {
    try {
        $payload = $raw | ConvertFrom-Json
        if ($payload.cwd) { $projectName = Split-Path -Leaf $payload.cwd }
    } catch { }
}

# --- helpers ----------------------------------------------------------------
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
# Weekly reset can be days out -- format in days + hours (e.g. "3d 1h") rather
# than a large hour count.
function Reset-In-Weekly([string]$iso) {
    if (-not $iso) { return '' }
    try {
        $rem = ([datetimeoffset]::Parse($iso)).UtcDateTime - (Get-Date).ToUniversalTime()
        if ($rem.TotalSeconds -lt 0) { return 'now' }
        $d = [int][math]::Floor($rem.TotalDays)
        if ($d -gt 0) { return "${d}d $($rem.Hours)h" }
        if ($rem.Hours -gt 0) { return "$($rem.Hours)h $($rem.Minutes)m" }
        return "$($rem.Minutes)m"
    } catch { return '' }
}
# Official usage from the same endpoint /usage calls, using the locally stored
# OAuth token. Linux/Windows: ~/.claude/.credentials.json. macOS: Keychain.
# Returns $null on any failure -> graceful skip (no post, state untouched).
function Get-RealUsage {
    try {
        $oauth = $null
        $credFile = Join-Path $claudeDir '.credentials.json'
        if (Test-Path $credFile) {
            $oauth = (Get-Content $credFile -Raw | ConvertFrom-Json).claudeAiOauth
        } elseif ($IsMacOS) {
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
# Did a window moving from $old% to $new% cross any milestone? (old < M <= new)
function Crossed-Milestone([int]$old, [int]$new) {
    foreach ($m in $Milestones) { if ($old -lt $m -and $new -ge $m) { return $true } }
    return $false
}

# --- current usage (throttled: hit the API at most once per 5 min) ----------
# PostToolUse fires on every tool, so an un-throttled fetch would call the usage
# API dozens of times per turn (and can get rate-limited). Cache the last fetch
# and reuse it within the TTL; crossings/resets are detected at up-to-5-min
# granularity (multi-percent jumps between fetches are shown as "old% -> new%").
$cacheFile = Join-Path $claudeDir 'discord_usage_throttle.json'
$ttl = 300
$now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$usage = $null
$attemptRecent = $false
if (Test-Path $cacheFile) {
    try {
        $c = Get-Content $cacheFile -Raw | ConvertFrom-Json
        if ($c.fetched_at -and (($now - [int]$c.fetched_at) -lt $ttl)) {
            $attemptRecent = $true                                  # hit (or TRIED) the API < TTL ago
            if ($c.five_hour -and $c.seven_day) { $usage = $c }     # ...and it succeeded -> reuse cache
        }
    } catch { }
}
# Only touch the API if our last ATTEMPT is older than the TTL -- this throttles
# successes AND failures alike, so a rate-limit/outage never makes us hammer the
# endpoint on every tool call. We record the attempt time either way.
if (-not $usage -and -not $attemptRecent) {
    $live = Get-RealUsage
    if ($live) {
        $usage = $live
        try {
            @{
                fetched_at = $now
                five_hour  = @{ utilization = $usage.five_hour.utilization; resets_at = "$($usage.five_hour.resets_at)" }
                seven_day  = @{ utilization = $usage.seven_day.utilization; resets_at = "$($usage.seven_day.resets_at)" }
            } | ConvertTo-Json -Compress | Set-Content -Path $cacheFile -NoNewline -Encoding ascii
        } catch { }
    } else {
        # Failed (or no creds): stamp the attempt so we back off for the full TTL
        # instead of retrying on the very next tool call.
        try { @{ fetched_at = $now } | ConvertTo-Json -Compress | Set-Content -Path $cacheFile -NoNewline -Encoding ascii } catch { }
    }
}
if (-not $usage) { exit 0 }   # no fresh data (failed, or backing off) -> do nothing
$cur5 = [int][math]::Floor([double]$usage.five_hour.utilization)
$cur7 = [int][math]::Floor([double]$usage.seven_day.utilization)

# --- last posted state ------------------------------------------------------
$stateFile = Join-Path $claudeDir 'discord_usage_pct_state.json'
$prev5 = -1; $prev7 = -1; $prevR5 = ''; $prevR7 = ''
if (Test-Path $stateFile) {
    try {
        $s = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($null -ne $s.five_hour) { $prev5 = [int]$s.five_hour }
        if ($null -ne $s.seven_day) { $prev7 = [int]$s.seven_day }
        if ($s.five_hour_resets_at) { $prevR5 = "$($s.five_hour_resets_at)" }
        if ($s.seven_day_resets_at) { $prevR7 = "$($s.seven_day_resets_at)" }
    } catch { }
}

# Crossing = a window advanced to a higher whole percent. A drop = that window
# reset (each window accumulates monotonically, then resets to ~0 at its
# boundary). Persist the new floors + reset times regardless before deciding.
$crossed5 = ($prev5 -ge 0 -and $cur5 -gt $prev5)
$crossed7 = ($prev7 -ge 0 -and $cur7 -gt $prev7)
$reset5 = ($prev5 -ge 0 -and $cur5 -lt $prev5)
$reset7 = ($prev7 -ge 0 -and $cur7 -lt $prev7)
$isReset = ($reset5 -or $reset7)
$firstRun = ($prev5 -lt 0 -and $prev7 -lt 0)

try {
    $newState = @{
        five_hour           = $cur5
        seven_day           = $cur7
        five_hour_resets_at = "$($usage.five_hour.resets_at)"
        seven_day_resets_at = "$($usage.seven_day.resets_at)"
    } | ConvertTo-Json -Compress
    Set-Content -Path $stateFile -Value $newState -NoNewline -Encoding ascii
} catch { }

# First ever run just establishes the baseline -- no post (avoids a spurious
# embed at whatever % the tracker happens to be installed at).
if ($firstRun) { exit 0 }
if (-not $isReset -and -not $crossed5 -and -not $crossed7) { exit 0 }

# --- glyphs + helpers -------------------------------------------------------
$folderGlyph = [System.Char]::ConvertFromUtf32(0x1F4C1)
$chartGlyph  = [System.Char]::ConvertFromUtf32(0x1F4CA)
$cycleGlyph  = [System.Char]::ConvertFromUtf32(0x1F504)
$boltGlyph   = [System.Char]::ConvertFromUtf32(0x26A1)
$greenGlyph  = [System.Char]::ConvertFromUtf32(0x1F7E2)
$partyGlyph  = [System.Char]::ConvertFromUtf32(0x1F389)

# Per-window display: show "old% -> new%" when it jumped more than one percent.
function Win-Line([string]$label, [int]$old, [int]$new, [bool]$crossed) {
    if ($crossed -and ($new - $old) -gt 1) { return "**$old% $([char]0x2192) $new%**  $label" }
    return "**$new%**  $label"
}
# A reset is "manual" (Anthropic cleared the limit early for everyone) when the
# previously-known reset time is still meaningfully in the future at the moment
# usage drops; otherwise the window simply rolled over on schedule.
function Reset-Kind([string]$prevIso) {
    if (-not $prevIso) { return 'scheduled' }
    try {
        $rem = ([datetimeoffset]::Parse($prevIso)).UtcDateTime - (Get-Date).ToUniversalTime()
        if ($rem.TotalSeconds -gt 300) { return 'manual' }
    } catch { }
    return 'scheduled'
}
function Send-Embed([string]$title, [string]$desc, [int]$color, $fields, [bool]$doPing) {
    $embed = @{
        color       = $color
        author      = @{ name = "$folderGlyph  $projectName" }
        title       = $title
        description = $desc
        footer      = @{ text = "$((Get-Date).ToString('ddd MMM d, yyyy  h:mm tt'))" }
        timestamp   = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($fields -and $fields.Count -gt 0) { $embed['fields'] = $fields }
    $body = @{ embeds = @($embed) }
    if ($doPing -and $UserId) {
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
}

# --- resets: one separate, highly-visible message per window ----------------
if ($reset5) {
    $bar = Usage-Bar $cur5
    if ((Reset-Kind $prevR5) -eq 'manual') {
        $title = "$boltGlyph  ANTHROPIC RESET THE 5-HOUR LIMIT"
        $desc  = "$partyGlyph **Anthropic just cleared the 5-hour limit early for everyone** -- you're back to **$cur5%** ahead of schedule!`n`n$bar  **$cur5%** used (5h window)"
        $color = 16766720   # gold -- special / global event
    } else {
        $title = "$cycleGlyph  5-HOUR LIMIT RESET"
        $desc  = "$greenGlyph Your **5-hour** window just rolled over -- back to **$cur5%**. Fresh window!`n`n$bar  **$cur5%** used (5h window)"
        $color = 5763719    # bright green -- fresh window
    }
    $f = @(); $r = Reset-In $usage.five_hour.resets_at
    if ($r) { $f += @{ name = 'Next 5h reset in'; value = $r; inline = $true } }
    Send-Embed $title $desc $color $f $true
}
if ($reset7) {
    $bar = Usage-Bar $cur7
    if ((Reset-Kind $prevR7) -eq 'manual') {
        $title = "$boltGlyph  ANTHROPIC RESET THE WEEKLY LIMIT"
        $desc  = "$partyGlyph **Anthropic just cleared the weekly limit early for everyone** -- you're back to **$cur7%** ahead of schedule!`n`n$bar  **$cur7%** used (weekly)"
        $color = 16766720   # gold
    } else {
        $title = "$cycleGlyph  WEEKLY LIMIT RESET"
        $desc  = "$greenGlyph Your **weekly** window just rolled over -- back to **$cur7%**. Fresh window!`n`n$bar  **$cur7%** used (weekly)"
        $color = 5763719
    }
    $f = @(); $r = Reset-In-Weekly $usage.seven_day.resets_at
    if ($r) { $f += @{ name = 'Next weekly reset in'; value = $r; inline = $true } }
    Send-Embed $title $desc $color $f $true
}

# --- routine 1% crossing update (windows that climbed, not the ones reset) --
if ((($crossed5 -and -not $reset5) -or ($crossed7 -and -not $reset7))) {
    $desc  = "$(Usage-Bar $cur5)  $(Win-Line 'used (5h window)' $prev5 $cur5 $crossed5)"
    $desc += "`n$(Usage-Bar $cur7)  $(Win-Line 'used (weekly)' $prev7 $cur7 $crossed7)"
    $ping = ((($crossed5 -and -not $reset5) -and (Crossed-Milestone $prev5 $cur5)) -or `
             (($crossed7 -and -not $reset7) -and (Crossed-Milestone $prev7 $cur7)))
    $color = if ($ping) {
        if ($cur5 -ge 100 -or $cur7 -ge 100) { 15158332 } else { 15844367 }  # red at limit, else amber
    } else { 3447003 }   # blurple for routine 1% updates
    $f = @()
    $r5 = Reset-In $usage.five_hour.resets_at
    if ($r5) { $f += @{ name = '5h resets in'; value = $r5; inline = $true } }
    $r7 = Reset-In-Weekly $usage.seven_day.resets_at
    if ($r7) { $f += @{ name = 'Weekly resets in'; value = $r7; inline = $true } }
    Send-Embed "$chartGlyph  Usage update" $desc $color $f $ping
}

exit 0
