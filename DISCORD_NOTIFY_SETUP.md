# Get pinged on Discord when Claude Code is waiting for you

This guide sets up Claude Code so it **sends you a Discord message (with a real ping/notification)** whenever it:

- 🔔 **needs your input** — a permission prompt, a question, an MCP elicitation, or Claude finishing/stuck and waiting for you (the ~60s idle signal). Detected via the `Notification` event gated on its `notification_type`, so it fires when Claude needs you — not on every routine turn-end. (There is intentionally **no `Stop` hook** — see Step D.)

It works by using **Claude Code hooks** (commands Claude runs automatically at certain points) plus a **Discord webhook** (a "post into this channel" URL). No bot, no token, no server to host.

Works on **macOS**, **Linux**, and **Windows**. Pick your OS section below — but do the two "Common steps" first.

---

## Common steps (everyone does these)

### 1. Create a Discord webhook

1. Open the Discord **server + channel** where you want the notifications. (It must be a *server* channel, not a DM — pings only fire in servers you're a member of.)
2. Click the gear ⚙️ next to the channel → **Edit Channel** → **Integrations** → **Webhooks** → **New Webhook**.
3. Name it (e.g. "Claude Waiting"), then click **Copy Webhook URL**.

The URL looks like `https://discord.com/api/webhooks/123456.../AbCdEf...`.

> ⚠️ **Treat this URL like a password.** Anyone who has it can post to your channel. Don't paste it into public chats or commit it to a repo.

### 2. Get your Discord user ID (so it can @-mention you)

A plain message won't push a phone/desktop notification — an **@-mention** will. To mention yourself, Claude needs your numeric user ID:

1. Discord → **User Settings** (gear) → **Advanced** → turn on **Developer Mode**.
2. Right-click your own name/avatar anywhere → **Copy User ID**.

You'll get a number like `291428797595516928`.

> If you'd rather **not** be hard-pinged for a given event, just leave the user ID off that hook (instructions below). The message still posts; it just won't notify.

---

Now jump to your OS:

- [macOS / Linux](#macos--linux)
- [Windows](#windows)

---

## macOS / Linux

> Requires `curl` (preinstalled everywhere). `jq` is optional but recommended (`brew install jq` on Mac, `sudo apt install jq` on Debian/Ubuntu) — without it you still get notifications, just without the extra detail line.

### Step A — Save your webhook URL to a file

Replace the URL with your own:

```bash
mkdir -p ~/.claude
printf '%s' 'PASTE_YOUR_WEBHOOK_URL_HERE' > ~/.claude/discord_webhook.txt
```

### Step B — Create the notifier script

Save this as `~/.claude/notify-discord.sh`:

```bash
#!/usr/bin/env bash
# notify-discord.sh — pings Discord when Claude Code is waiting for you.
# Usage (from a hook): notify-discord.sh <Stop|Notification> [discord_user_id]
# Reads the hook's JSON payload on stdin.

EVENT="${1:-Stop}"
USER_ID="${2:-}"

WEBHOOK_FILE="$HOME/.claude/discord_webhook.txt"
[ -f "$WEBHOOK_FILE" ] || exit 0
WEBHOOK_URL="$(tr -d '[:space:]' < "$WEBHOOK_FILE")"
[ -n "$WEBHOOK_URL" ] || exit 0

RAW="$(cat)"            # hook JSON arrives on stdin
PROJECT="$(basename "$PWD")"
DETAIL=""

if command -v jq >/dev/null 2>&1; then
  MSG="$(printf '%s' "$RAW" | jq -r '.message // empty' 2>/dev/null)"
  CWD="$(printf '%s' "$RAW" | jq -r '.cwd // empty' 2>/dev/null)"
  [ -n "$MSG" ] && DETAIL=" — $MSG"
  [ -n "$CWD" ] && PROJECT="$(basename "$CWD")"
fi

MENTION=""
[ -n "$USER_ID" ] && MENTION="<@${USER_ID}> "

if [ "$EVENT" = "Notification" ]; then
  CONTENT="${MENTION}🔔 **Claude Code needs you** in \`${PROJECT}\`${DETAIL}"
else
  CONTENT="${MENTION}✅ **Claude finished its turn** in \`${PROJECT}\` — waiting for your reply."
fi

# Build the JSON payload safely.
if command -v jq >/dev/null 2>&1; then
  if [ -n "$USER_ID" ]; then
    PAYLOAD="$(jq -nc --arg c "$CONTENT" --arg u "$USER_ID" \
      '{content:$c, allowed_mentions:{users:[$u]}}')"
  else
    PAYLOAD="$(jq -nc --arg c "$CONTENT" '{content:$c}')"
  fi
else
  # Fallback without jq: escape backslashes and double quotes in the content.
  ESC="${CONTENT//\\/\\\\}"; ESC="${ESC//\"/\\\"}"
  if [ -n "$USER_ID" ]; then
    PAYLOAD="{\"content\":\"${ESC}\",\"allowed_mentions\":{\"users\":[\"${USER_ID}\"]}}"
  else
    PAYLOAD="{\"content\":\"${ESC}\"}"
  fi
fi

# Never let a failed notification surface as a hook error.
curl -s -m 10 -H "Content-Type: application/json" -X POST -d "$PAYLOAD" "$WEBHOOK_URL" >/dev/null 2>&1
exit 0
```

Make it executable:

```bash
chmod +x ~/.claude/notify-discord.sh
```

### Step C — Test the script directly

Replace `YOUR_USER_ID` with your number. You should see a ping land in Discord:

```bash
echo '{"message":"setup test"}' | ~/.claude/notify-discord.sh Notification YOUR_USER_ID
```

If nothing arrives, see [Troubleshooting](#troubleshooting).

### Step D — Add the hooks to your settings

Your settings file is `~/.claude/settings.json`. **If it already exists, merge** the `"hooks"` block into it — don't overwrite the whole file (you'd wipe your model/plugins/etc.). If it doesn't exist, create it with exactly this:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "permission_prompt|worker_permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/notify-discord.sh\" Notification YOUR_USER_ID",
            "async": true
          }
        ]
      }
    ]
  }
}
```

Replace `YOUR_USER_ID` with your Discord user ID.

- There is intentionally **no `Stop` hook**. Stop fires at the end of *every* turn (including phase boundaries and background-workflow steps), so it pings when Claude is not actually waiting — and it double-pings alongside the real "needs input" Notification. Only the `Notification` hook means Claude needs you.
- The `matcher` whitelists the `notification_type` values that mean Claude is genuinely blocked on you: tool **permission** prompts, MCP **elicitation** dialogs, and the **idle** "waiting for your input" prompt. It deliberately drops informational types (`auth_success`, `elicitation_complete`/`elicitation_response`, `computer_use_*`, `push_notification`).
- Want pings **only** for hard blocks (drop the 60s idle reminder)? Remove `idle_prompt` from the `matcher`.

Then **[reload Claude Code](#activating-the-hooks)**.

---

## Windows

> Uses built-in PowerShell — no extra tools to install.

### Step A — Save your webhook URL to a file

In PowerShell, replace the URL with your own:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude" | Out-Null
'PASTE_YOUR_WEBHOOK_URL_HERE' | Set-Content "$env:USERPROFILE\.claude\discord_webhook.txt" -NoNewline
```

### Step B — Create the notifier script

Save this as `%USERPROFILE%\.claude\notify-discord.ps1`.

> **Important:** keep this file **pure ASCII**. Windows PowerShell 5.1 reads `.ps1` files in the legacy codepage when there's no byte-order mark, which corrupts emoji/dashes written as literal characters. This script builds them from Unicode code points at runtime to avoid that — don't paste emoji directly into it.

```powershell
# notify-discord.ps1 -- pings Discord when Claude Code is waiting for you.
# Invoked by the Stop and Notification hooks. Receives the hook's JSON on stdin.
param(
    [ValidateSet('Stop', 'Notification')]
    [string]$Event = 'Stop',
    [string]$UserId = ''   # Discord user ID to @-mention (empty = no ping)
)

$ErrorActionPreference = 'Stop'

$webhookFile = Join-Path $env:USERPROFILE '.claude\discord_webhook.txt'
if (-not (Test-Path $webhookFile)) { exit 0 }
$webhookUrl = (Get-Content $webhookFile -Raw).Trim()
if (-not $webhookUrl) { exit 0 }

$raw = ($input | Out-String)
$projectName = Split-Path -Leaf (Get-Location)
$detail = ''
if ($raw) {
    try {
        $payload = $raw | ConvertFrom-Json
        if ($payload.message) { $detail = ' -- ' + $payload.message }
        if ($payload.cwd)     { $projectName = Split-Path -Leaf $payload.cwd }
    } catch { }
}

# Unicode glyphs built from code points to keep this source ASCII-only.
$bell  = [System.Char]::ConvertFromUtf32(0x1F514)
$check = [System.Char]::ConvertFromUtf32(0x2705)

$mention = ''
if ($UserId) { $mention = "<@$UserId> " }

if ($Event -eq 'Notification') {
    $content = "$mention$bell **Claude Code needs you** in ``$projectName``$detail"
} else {
    $content = "$mention$check **Claude finished its turn** in ``$projectName`` -- waiting for your reply."
}

$body = @{ content = $content }
if ($UserId) { $body['allowed_mentions'] = @{ users = @($UserId) } }

try {
    Invoke-RestMethod -Uri $webhookUrl -Method Post -ContentType 'application/json' `
        -Body ($body | ConvertTo-Json -Compress -Depth 5) | Out-Null
} catch { }
exit 0
```

### Step C — Test the script directly

Replace `YOUR_USER_ID`. You should see a ping in Discord:

```powershell
'{"message":"setup test"}' | & "$env:USERPROFILE\.claude\notify-discord.ps1" -Event Notification -UserId YOUR_USER_ID
```

### Step D — Add the hooks to your settings

Your settings file is `%USERPROFILE%\.claude\settings.json`. **If it already exists, merge** the `"hooks"` block in — don't overwrite the whole file. If it doesn't exist, create it with exactly this:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "permission_prompt|worker_permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog",
        "hooks": [
          {
            "type": "command",
            "shell": "powershell",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"$env:USERPROFILE\\.claude\\notify-discord.ps1\" -Event Notification -UserId YOUR_USER_ID",
            "async": true
          }
        ]
      }
    ]
  }
}
```

Replace `YOUR_USER_ID` with your Discord user ID.

- There is intentionally **no `Stop` hook**. Stop fires at the end of *every* turn (including phase boundaries and background-workflow steps), so it pings when Claude is not actually waiting — and it double-pings alongside the real "needs input" Notification. Only the `Notification` hook means Claude needs you.
- The `matcher` whitelists the `notification_type` values that mean Claude is genuinely blocked on you: tool **permission** prompts, MCP **elicitation** dialogs, and the **idle** "waiting for your input" prompt. It deliberately drops informational types (`auth_success`, `elicitation_complete`/`elicitation_response`, `computer_use_*`, `push_notification`).
- Want pings **only** for hard blocks (drop the 60s idle reminder)? Remove `idle_prompt` from the `matcher`.

Then **[reload Claude Code](#activating-the-hooks)**.

---

## Activating the hooks

If you edited `settings.json` while Claude Code was running, the change may not take effect until you reload. Either:

- Open the **`/hooks`** menu once (this reloads hook config), **or**
- Restart Claude Code.

After that, you'll get pinged automatically. (Claude Code only surfaces a "Ran N hooks" line when a hook errors or is slow — silent success is invisible by design, so don't worry if you see nothing in the UI.)

---

## User-level vs project-level setup

The steps above install everything at the **user level** (`~/.claude/settings.json`), so the hooks fire in **every project** you open on that machine. That's the simplest choice for personal use and it's what this guide defaults to.

You can instead scope the hooks to a **single project** — useful if you only want notifications for one repo, or you want to share the setup with a team.

### Where the files live

| File | User level | Project level |
|---|---|---|
| Hooks (`settings.json`) | `~/.claude/settings.json` | `<project>/.claude/settings.json` (shared, committed) **or** `<project>/.claude/settings.local.json` (personal, git-ignored) |
| Notifier script | `~/.claude/notify-discord.{sh,ps1}` | Keep it in `~/.claude/` and reference it by absolute path (recommended), or commit it under `<project>/.claude/` |
| Webhook URL | `~/.claude/discord_webhook.txt` | **Keep in `~/.claude/`** — never commit a webhook URL into a repo |

The hook **commands stay identical** — they already point at `$HOME/.claude/...` (or `$env:USERPROFILE\.claude\...`), so the script and webhook can live in your home dir while only the `hooks` block moves into the project.

### How to scope it to one project

1. **Remove** the `"hooks"` block from `~/.claude/settings.json` (otherwise it runs everywhere).
2. Create `<project>/.claude/settings.json` (or `.local.json`) and put the **same `"hooks"` block** there.
3. Leave `notify-discord.{sh,ps1}` and `discord_webhook.txt` in `~/.claude/` — the commands already reference them there.

### Heads-up: hooks from all sources are *additive*

Settings layer **user → project → local**, but hooks **don't override each other — they stack**. If you keep the hooks at the user level **and** add them in a project, you'll get **duplicate notifications** (two pings per event) inside that project. Pick one scope, not both.

### Sharing with a team

- **Committed `<project>/.claude/settings.json`** is shared with everyone who clones the repo — good for a team that all wants notifications. But:
  - Each teammate has a **different Discord user ID**, so a hardcoded `YOUR_USER_ID` would ping *you* for *their* turns. For team use, either drop the user ID from the committed hook (messages post without pinging anyone), or have each person override the ID in their own git-ignored `<project>/.claude/settings.local.json`.
  - Every teammate must still do the per-machine steps: install the **script** and create their own **`~/.claude/discord_webhook.txt`** (these aren't committed). Point them at this guide.
- **`<project>/.claude/settings.local.json`** is git-ignored by default — use it for *your personal* per-project hooks/user ID that you don't want to share.

## Customizing

- **Edit the wording / emoji:** change the `$content` / `CONTENT` lines in the script.
- **Quieter (hard blocks only):** to skip the ~60s idle "your turn" signal and ping only for permission prompts / questions / elicitation, remove `idle_prompt` from the `Notification` matcher **and** the script allowlist. Tune the idle delay via `messageIdleNotifThresholdMs` in `settings.json` (default `60000`).
- **Turn everything off temporarily:** in `settings.json` set `"disableAllHooks": true`, or just delete the `"hooks"` block.
- **Rotate your webhook:** if the URL ever leaks, delete the webhook in Discord, make a new one, and overwrite `~/.claude/discord_webhook.txt`. No other changes needed.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| No message at all | Webhook file missing/empty, or URL wrong. Re-check `~/.claude/discord_webhook.txt`. Test the script directly (Step C). |
| Message posts but **no ping** | Wrong user ID, **or** you're not a member of that server, **or** the webhook channel is a DM (mentions only ping in server channels you can see). |
| Script errors on Windows about unexpected tokens | The `.ps1` got saved with literal emoji in a non-UTF-8 encoding. Re-save using the exact ASCII version above (it builds emoji at runtime). |
| Hooks never fire | Did you reload? Open `/hooks` or restart. Also verify `settings.json` is valid JSON (a syntax error silently disables *all* settings in that file). |
| `curl: command not found` (Linux) | Install curl: `sudo apt install curl`. |
| Detail line never appears (Mac/Linux) | `jq` isn't installed — optional. Install it for the extra context, or ignore. |

---

## How it works (for the curious)

- **Hooks** are commands Claude Code runs at lifecycle events. This setup uses only the `Notification` event (which fires when Claude wants your input/permission, an MCP elicitation, or has gone idle waiting), gated on `notification_type`. The `Stop` event (every turn-end) is deliberately not used — it isn't a needs-input signal.
- Each hook pipes a small **JSON payload** to our script on stdin (it may include a `message` and `cwd`). The script reads it, formats a Discord message, and POSTs it to your **webhook**.
- `allowed_mentions` is set to only your user ID, so the `<@id>` actually pushes a notification and nothing else (no accidental `@everyone`).
- `"async": true` makes the hook run in the background so it never adds any delay to your Claude Code session.
```
