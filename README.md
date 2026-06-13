# Claude Code → Discord notifier

Get **Discord notifications** from [Claude Code](https://claude.com/claude-code) using hooks + webhooks — no bot, no token, no server to host. Two independent feeds:

- 🔔 **Ping feed** — pings you (real @-mention) **only when Claude actually needs your input** — a permission prompt, a question, an MCP elicitation, or Claude going idle/stuck and waiting for your reply (the ~60s idle signal). Gated on `notification_type`, so it skips routine turn-ends and informational notices. The embed shows your **official usage** (5-hour + weekly %, straight from the same endpoint `/usage` uses) and the token cost of the last prompt.
- 📋 **Activity feed** — a separate, **no-ping** channel that streams what's happening: your prompts, subagents starting/finishing (task → model → tools used → result), `ultracode` workflow results, and Claude's messages — each tagged with the project directory, model, effort, and a timestamp.

Two implementations with the same behavior:

| Platform | Scripts | Runtime |
|---|---|---|
| **Windows** | [`windows/`](windows/) (`*.ps1`) | built-in Windows PowerShell 5.1 |
| **macOS / Linux** | [`macos-linux/`](macos-linux/) (`*.sh`) | `bash` + `curl` + `jq` |

> ⚠️ **No secrets in this repo.** The scripts read your webhook URLs from local files (`~/.claude/discord_webhook.txt`, `~/.claude/discord_activity_webhook.txt`) and never embed them. Treat those URLs like passwords — don't commit them anywhere.

---

## What you'll need

1. A Discord **server channel** (not a DM — pings only fire in servers you're a member of).
2. One or two **webhooks** (Channel → Edit → Integrations → Webhooks → New Webhook → *Copy Webhook URL*). Use two channels if you want the chatty activity feed separate from your pings.
3. Your numeric **Discord user ID** (User Settings → Advanced → Developer Mode on; then right-click your name → *Copy User ID*). Only the ping feed uses it.
4. **macOS/Linux only:** `jq` and `curl` (`brew install jq`, `sudo apt install jq`, etc.). curl is usually preinstalled.

---

## Setup

### 1. Copy the scripts to `~/.claude/`
- **Windows:** copy `windows\notify-discord.ps1` and `windows\notify-discord-activity.ps1` into `%USERPROFILE%\.claude\`.
- **macOS/Linux:** copy `macos-linux/notify-discord.sh` and `macos-linux/notify-discord-activity.sh` into `~/.claude/`, then `chmod +x ~/.claude/notify-discord*.sh`.

### 2. Save your webhook URL(s)
```bash
# macOS/Linux
printf '%s' 'PASTE_PING_WEBHOOK_URL'     > ~/.claude/discord_webhook.txt
printf '%s' 'PASTE_ACTIVITY_WEBHOOK_URL' > ~/.claude/discord_activity_webhook.txt   # optional (activity feed)
```
```powershell
# Windows (PowerShell)
'PASTE_PING_WEBHOOK_URL'     | Set-Content "$env:USERPROFILE\.claude\discord_webhook.txt" -NoNewline
'PASTE_ACTIVITY_WEBHOOK_URL' | Set-Content "$env:USERPROFILE\.claude\discord_activity_webhook.txt" -NoNewline
```
(You can point both files at the same webhook if you want everything in one channel.)

### 3. Add the hooks to `settings.json`
Merge the `"hooks"` block from the matching `settings.example.json` ([windows](windows/settings.example.json) / [macos-linux](macos-linux/settings.example.json)) into `~/.claude/settings.json` (create it if missing). **Replace `YOUR_DISCORD_USER_ID`** with your ID. If you only want the ping feed, just include the `Notification` hook.

### 4. Reload
Open the **`/hooks`** menu once (reloads hook config) or restart Claude Code.

### 5. Test (optional)
```bash
# macOS/Linux
echo '{"message":"setup test"}' | bash ~/.claude/notify-discord.sh Notification YOUR_DISCORD_USER_ID
```
```powershell
# Windows
'{"message":"setup test"}' | & "$env:USERPROFILE\.claude\notify-discord.ps1" -Event Notification -UserId YOUR_DISCORD_USER_ID
```

---

## Activity feed events

| Event (hook) | Embed | Shows |
|---|---|---|
| `UserPromptSubmit` | 💬 Your prompt | your prompt text |
| `SubagentStart` | ▶ Agent started | task it was given · agent type · model |
| `SubagentStop` | ✅ Agent done | result · model · effort · tools used · parent workflow |
| `PostToolUse` (`Workflow`) | ⚙ Workflow finished | consolidated workflow result |
| `MessageDisplay` | 🤖 Claude | the assistant's reply text · model · effort |

Every embed carries the **project directory** (author line) and a **dated timestamp** (footer).

---

## Usage percentages (ping feed)

The ping embed shows your **real** Claude usage by calling `GET https://api.anthropic.com/api/oauth/usage` (the same endpoint the `/usage` command uses) with your locally stored OAuth token:
- **Linux / Windows:** token read from `~/.claude/.credentials.json`.
- **macOS:** token read from the login **Keychain** (`security find-generic-password -s "Claude Code-credentials" -w`). If the usage line shows *"live usage unavailable"*, confirm that service name on your Mac.

This is an **undocumented internal endpoint** and may change between Claude Code versions; if it ever stops working the embed simply omits usage and everything else keeps running. The token is only ever sent to `api.anthropic.com` (your own usage data).

---

## Customizing
- **Quieter (hard blocks only):** to ping *only* for permission prompts / questions / elicitation and skip the ~60s idle "your turn" signal, remove `idle_prompt` from the `Notification` `matcher` **and** the script allowlist.
- **Tune the idle delay:** `idle_prompt` fires after ~60s idle; set `messageIdleNotifThresholdMs` in `settings.json` (default `60000`). Heads-up: it tracks main-thread idle, so a long background workflow can trigger it ~60s in.
- **Only the ping feed:** omit the activity hooks (`UserPromptSubmit`, `SubagentStart`, `SubagentStop`, `PostToolUse`, `MessageDisplay`).
- **Everything in one channel:** point both webhook files at the same URL.

## Known limits (Claude Code hooks)
- The model's **thinking/reasoning** is not exposed to any hook, so it can't be forwarded.
- Live **workflow phase progress** isn't exposed either — you get per-agent start/done events and the final workflow result, not phase-by-phase narration.
- **Main-agent effort** isn't in any payload; it's read from `settings.json` `effortLevel`, so it won't reflect a live `/effort` or fast-mode override.
- The `MessageDisplay` feed posts on every assistant message (can be chatty).

## Troubleshooting
| Symptom | Fix |
|---|---|
| No message at all | Check the webhook file exists/has the right URL; run the test command in step 5. |
| Message posts but no ping | Wrong user ID, you're not in that server, or the webhook is a DM channel. |
| Hooks never fire | Reload via `/hooks` or restart; verify `settings.json` is valid JSON. |
| `jq: command not found` (macOS/Linux) | Install jq. |
| Usage shows "live usage unavailable" | Token expired between refreshes (transient), or on macOS the Keychain service name differs. |

## License
MIT — see [LICENSE](LICENSE).
