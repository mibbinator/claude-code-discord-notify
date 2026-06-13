# notify-discord-activity.ps1 -- posts Claude Code ACTIVITY to a SEPARATE Discord
# channel with NO @-mention (info feed only), using rich embeds. Wired to
# UserPromptSubmit, SubagentStart, SubagentStop, PostToolUse(Workflow), and
# MessageDisplay hooks. Receives the hook JSON on stdin.
#
# Payload field names verified from real fires logged to discord_activity_debug.jsonl.
param(
    [string]$Kind = ''   # UserPrompt | SubagentStart | SubagentStop | Workflow | Message
)

$ErrorActionPreference = 'Stop'

# (stdin is read as UTF-8 explicitly below, where $raw is assigned)

# Portable home -> ~/.claude (Windows / macOS / Linux).
$base = if ($HOME) { "$HOME" } else { "$env:USERPROFILE" }
$claudeDir = Join-Path $base '.claude'

$webhookFile = Join-Path $claudeDir 'discord_activity_webhook.txt'
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

# Self-documenting log of the real payloads (safe to delete).
try {
    $logFile = Join-Path $claudeDir 'discord_activity_debug.jsonl'
    Add-Content -Path $logFile -Encoding utf8 -Value (@{ at = (Get-Date).ToString('o'); kind = $Kind; raw = $raw } | ConvertTo-Json -Compress -Depth 20)
} catch { }

$payload = $null
if ($raw) { try { $payload = $raw | ConvertFrom-Json } catch { } }
if (-not $Kind -and $payload.hook_event_name) { $Kind = "$($payload.hook_event_name)" }

function First-Prop($obj, [string[]]$names) {
    if (-not $obj) { return '' }
    foreach ($n in $names) { $v = $obj.$n; if ($null -ne $v -and "$v" -ne '') { return $v } }
    return ''
}
function Truncate([string]$s, [int]$max) {
    if (-not $s) { return '' }
    $s = $s.Trim()
    if ($s.Length -le $max) { return $s }
    return $s.Substring(0, $max).TrimEnd() + ' ...'
}
function Get-AgentTask([string]$path) {
    if (-not $path -or -not (Test-Path $path)) { return '' }
    try {
        $first = Get-Content $path -TotalCount 1
        if ($first) {
            $o = $first | ConvertFrom-Json
            $c = $o.message.content
            if ($c -is [string]) { return $c }
            elseif ($c) { foreach ($b in $c) { if ($b.type -eq 'text' -and $b.text) { return $b.text } } }
        }
    } catch { }
    return ''
}
function Get-AgentToolTally([string]$path) {
    if (-not $path -or -not (Test-Path $path)) { return '' }
    try {
        $counts = @{}
        foreach ($ln in Get-Content $path) {
            if ($ln -notmatch '"type":"tool_use"') { continue }
            try { $o = $ln | ConvertFrom-Json } catch { continue }
            if ($o.type -eq 'assistant' -and $o.message.content) {
                foreach ($b in $o.message.content) {
                    if ($b.type -eq 'tool_use' -and $b.name) {
                        if ($counts.ContainsKey($b.name)) { $counts[$b.name]++ } else { $counts[$b.name] = 1 }
                    }
                }
            }
        }
        if ($counts.Count -eq 0) { return '' }
        return (($counts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "``$($_.Key)`` x$($_.Value)" }) -join '  ')
    } catch { return '' }
}
function Find-AgentTranscript([string]$sessionTranscript, [string]$agentId) {
    if (-not $sessionTranscript -or -not $agentId) { return '' }
    $dir = Join-Path ($sessionTranscript -replace '\.jsonl$', '') 'subagents'
    if (-not (Test-Path $dir)) { return '' }
    $hit = Get-ChildItem -Path $dir -Recurse -Filter "agent-$agentId.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return ''
}
# Pretty model id, e.g. claude-opus-4-8 -> "Opus 4.8", claude-haiku-4-5-2025... -> "Haiku 4.5".
function Format-Model([string]$m) {
    if (-not $m) { return '' }
    if ($m -match 'claude-([a-z]+)-(\d+)-(\d+)') { return ((Get-Culture).TextInfo.ToTitleCase($matches[1])) + " $($matches[2]).$($matches[3])" }
    if ($m -match 'claude-([a-z]+)-(\d+)')        { return ((Get-Culture).TextInfo.ToTitleCase($matches[1])) + " $($matches[2])" }
    return $m
}
function Format-Effort([string]$e) {
    if (-not $e) { return '' }
    if ($e -eq 'xhigh') { return 'X-High' }
    return (Get-Culture).TextInfo.ToTitleCase($e)
}
# Most recent message.model from a transcript (reads only the tail for speed).
function Get-LastModel([string]$path) {
    if (-not $path -or -not (Test-Path $path)) { return '' }
    try {
        $tail = Get-Content $path -Tail 80
        for ($i = $tail.Count - 1; $i -ge 0; $i--) {
            if ($tail[$i] -match '"model":"([^"]+)"') { return $matches[1] }
        }
    } catch { }
    return ''
}
# Main-agent effort: best available local source is the configured effortLevel.
function Get-MainEffort {
    try {
        $s = Get-Content (Join-Path $claudeDir 'settings.json') -Raw | ConvertFrom-Json
        if ($s.effortLevel) { return "$($s.effortLevel)" }
    } catch { }
    return ''
}
# Official 5-hour usage %, cached ~60s so the high-frequency activity feed
# (esp. MessageDisplay) doesn't hit api.anthropic.com on every event. Returns
# '' on any failure (cached too, to avoid retry storms while the API is down).
function Get-UsagePct {
    $cacheFile = Join-Path $claudeDir 'discord_usage_cache.json'
    try {
        if (Test-Path $cacheFile) {
            $c = Get-Content $cacheFile -Raw | ConvertFrom-Json
            $age = ((Get-Date).ToUniversalTime() - ([datetimeoffset]::Parse($c.at)).UtcDateTime).TotalSeconds
            if ($age -lt 60) { return "$($c.pct)" }
        }
    } catch { }
    $pct = ''
    try {
        $oauth = $null
        $credFile = Join-Path $claudeDir '.credentials.json'
        if (Test-Path $credFile) { $oauth = (Get-Content $credFile -Raw | ConvertFrom-Json).claudeAiOauth }
        elseif ($IsMacOS) { $j = & security find-generic-password -s 'Claude Code-credentials' -w 2>$null; if ($j) { $oauth = ($j | ConvertFrom-Json).claudeAiOauth } }
        if ($oauth -and $oauth.accessToken) {
            $h = @{ 'Authorization' = "Bearer $($oauth.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20'; 'anthropic-version' = '2023-06-01'; 'User-Agent' = 'claude-discord-usage-hook' }
            $u = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $h -Method Get -TimeoutSec 8
            if ($u.five_hour) { $pct = "$([int][math]::Round([double]$u.five_hour.utilization))" }
        }
    } catch { $pct = '' }
    try { @{ at = (Get-Date).ToUniversalTime().ToString('o'); pct = $pct } | ConvertTo-Json -Compress | Set-Content -Path $cacheFile -NoNewline -Encoding ascii } catch { }
    return $pct
}

# Glyphs from code points (keeps this source ASCII-safe for PS 5.1).
$gFolder = [System.Char]::ConvertFromUtf32(0x1F4C1)
$gSpeech = [System.Char]::ConvertFromUtf32(0x1F4AC)
$gPlay   = [System.Char]::ConvertFromUtf32(0x25B6)
$gCheck  = [System.Char]::ConvertFromUtf32(0x2705)
$gGear   = [System.Char]::ConvertFromUtf32(0x2699)
$gRobot  = [System.Char]::ConvertFromUtf32(0x1F916)

$cwd = First-Prop $payload @('cwd')
$dirLabel = if ($cwd) { Split-Path -Leaf $cwd } else { '' }

$title = ''; $desc = ''; $color = 9807270; $fields = @()

switch -Regex ($Kind) {
    'UserPrompt' {
        $p = First-Prop $payload @('prompt', 'user_prompt', 'message', 'text', 'content', 'prompt_text')
        if ($p -is [array]) { $p = (($p | ForEach-Object { if ($_.text) { $_.text } else { "$_" } }) -join ' ') }
        if (-not "$p".Trim()) { exit 0 }
        $color = 5793266; $title = "$gSpeech  Your prompt"; $desc = Truncate ([string]$p) 2000
    }
    'SubagentStart' {
        $type  = First-Prop $payload @('agent_type', 'subagent_type', 'agentType')
        $id    = First-Prop $payload @('agent_id', 'agentId', 'id')
        $tpath = First-Prop $payload @('agent_transcript_path')
        if (-not $tpath) { $tpath = Find-AgentTranscript (First-Prop $payload @('transcript_path')) $id }
        $color = 1752220; $title = "$gPlay  Agent started"
        $task  = Truncate (Get-AgentTask $tpath) 1500
        $desc  = if ($task) { $task } else { '_(task not captured yet)_' }
        if ($type) { $fields += @{ name = 'Agent'; value = "``$type``"; inline = $true } }
        $mdl = Format-Model (Get-LastModel $tpath)
        if ($mdl) { $fields += @{ name = 'Model'; value = "``$mdl``"; inline = $true } }
    }
    'SubagentStop' {
        $type  = First-Prop $payload @('agent_type', 'subagent_type', 'agentType')
        $tpath = First-Prop $payload @('agent_transcript_path')
        if (-not $tpath) { $tpath = Find-AgentTranscript (First-Prop $payload @('transcript_path')) (First-Prop $payload @('agent_id','agentId','id')) }
        $color = 3066993; $title = "$gCheck  Agent done"
        $result = Truncate (First-Prop $payload @('last_assistant_message')) 1800
        $desc = if ($result) { $result } else { '_(no result captured)_' }
        if ($type) { $fields += @{ name = 'Agent'; value = "``$type``"; inline = $true } }
        $mdl = Format-Model (Get-LastModel $tpath)
        if ($mdl) { $fields += @{ name = 'Model'; value = "``$mdl``"; inline = $true } }
        $eff = Format-Effort (First-Prop $payload.effort @('level'))
        if ($eff) { $fields += @{ name = 'Effort'; value = $eff; inline = $true } }
        $tools = Get-AgentToolTally $tpath
        if ($tools) { $fields += @{ name = 'Tools used'; value = (Truncate $tools 1000); inline = $false } }
        $wf = $null
        if ($payload.background_tasks) { $wf = $payload.background_tasks | Where-Object { $_.type -eq 'workflow' } | Select-Object -First 1 }
        if ($wf) { $fields += @{ name = 'Workflow'; value = (Truncate "$($wf.name) -- $($wf.description) [$($wf.status)]" 1000); inline = $false } }
    }
    'Workflow' {
        $resp = $payload.tool_response; if (-not $resp) { $resp = $payload.tool_output }; if (-not $resp) { $resp = $payload.tool_result }
        $respStr = ''
        if ($resp -is [string]) { $respStr = $resp }
        elseif ($resp) { try { $respStr = ($resp | ConvertTo-Json -Compress -Depth 8) } catch { $respStr = "$resp" } }
        $color = 15105570; $title = "$gGear  Workflow finished"
        $desc = if ("$respStr".Trim()) { Truncate $respStr 2000 } else { '_(no result captured)_' }
    }
    'Message' {
        if (($payload.PSObject.Properties.Name -contains 'final') -and (-not $payload.final)) { exit 0 }
        $msg = First-Prop $payload @('delta', 'message_text', 'message', 'text', 'content')
        if ($msg -is [array]) { $msg = (($msg | ForEach-Object { if ($_.text) { $_.text } else { "$_" } }) -join "`n") }
        if (-not "$msg".Trim()) { exit 0 }
        $color = 9807270; $title = "$gRobot  Claude"; $desc = Truncate ([string]$msg) 2000
        $mdl = Format-Model (Get-LastModel (First-Prop $payload @('transcript_path')))
        if ($mdl) { $fields += @{ name = 'Model'; value = "``$mdl``"; inline = $true } }
        $eff = Format-Effort (Get-MainEffort)
        if ($eff) { $fields += @{ name = 'Effort'; value = $eff; inline = $true } }
    }
    default {
        $title = "($Kind)"; $desc = Truncate $raw 1500
    }
}

if (-not "$desc".Trim() -and -not $fields.Count) { exit 0 }

$embed = @{ color = $color; timestamp = (Get-Date).ToUniversalTime().ToString('o') }
if ($title) { $embed['title'] = $title }
if ("$desc".Trim()) { $embed['description'] = $desc }
if ($fields.Count) { $embed['fields'] = $fields }
if ($dirLabel) { $embed['author'] = @{ name = "$gFolder  $dirLabel" } }
$footerText = (Get-Date).ToString('ddd MMM d, yyyy  h:mm:ss tt')
$usagePct = Get-UsagePct
if ($usagePct) { $footerText += "  -  $usagePct% of 5h" }
$embed['footer'] = @{ text = $footerText }

# allowed_mentions.parse = [] guarantees NO pings.
$body = @{ embeds = @($embed); allowed_mentions = @{ parse = @() } }
try {
    $json = $body | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Invoke-RestMethod -Uri $webhookUrl -Method Post -ContentType 'application/json; charset=utf-8' `
        -Body $bytes -TimeoutSec 8 | Out-Null
} catch { }
exit 0
