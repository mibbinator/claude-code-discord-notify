# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Hook scripts that send Claude Code lifecycle events to Discord via webhooks (no bot, no server). There is **no build system** — the deliverables are standalone scripts invoked by Claude Code hooks. Three feeds, two platform implementations that must stay at **behavioral parity**:

- **Ping feed** (`notify-discord.{ps1,sh}`) — fires on the `Notification` hook **only**, gated (settings `matcher` + in-script allowlist) to `notification_type` values that mean Claude needs you (`permission_prompt`, `worker_permission_prompt`, `idle_prompt`, `elicitation_dialog`, `elicitation_url_dialog`); @-mentions the user; embed shows official usage % + last prompt's token cost. The `Stop` hook is intentionally NOT wired — turn-end isn't a needs-input signal and caused double/false pings. (AskUserQuestion, tool permissions, and plan-mode all surface as `permission_prompt`. `idle_prompt` is the ~60s "your turn / Claude finished or stuck and waiting" signal; remove it from the matcher + allowlist for hard-blocks-only.)
- **Activity feed** (`notify-discord-activity.{ps1,sh}`) — fires on `UserPromptSubmit`, `SubagentStart`, `SubagentStop`, `PostToolUse`(matcher `Workflow`), `MessageDisplay`; never pings.
- **Usage tracker** (`notify-discord-usage.{ps1,sh}`) — fires on `PostToolUse`(matcher `*`) + `Stop`; posts only when `floor(utilization)` rises for the 5h or weekly window (~every 1%), OR when a window resets. Silent for routine 1% ticks; @-mentions the user (a) when a crossing passes a milestone (`$Milestones`/`MILESTONES` = 25/50/80/90/100), or (b) on a **reset** — detected as `cur% < prev%` (each window accumulates monotonically then drops to ~0 at its boundary), posted as a green 🔄 "limit reset" embed naming the window(s). Last-posted % persists in `~/.claude/discord_usage_pct_state.json` (first run baselines silently). Webhook from `~/.claude/discord_usage_webhook.txt`. Reuses the ping feed's usage-fetch/OAuth/bar/reset-in logic verbatim — keep them in sync.

`windows/` = PowerShell (built-in Windows PowerShell 5.1). `macos-linux/` = bash + `curl` + `jq`. **Any behavior change must be made in BOTH** the `.ps1` and the `.sh` for that feed.

## Dev → live workflow (critical — editing repo files does nothing on its own)

This folder is the git repo (auto-pushes on every commit via `.git/hooks/post-commit`). The scripts that actually run live in `~/.claude/`, separate from this repo. To make a change take effect:

1. Edit the script here in `windows/` (or `macos-linux/`).
2. `git add -A && git commit -m "..."` — the post-commit hook pushes to GitHub automatically.
3. Run `.\deploy.ps1` (Windows) or `bash deploy.sh` (macOS/Linux) — copies the platform scripts into `~/.claude/`.
4. Reload: open the `/hooks` menu once, or restart Claude Code.

Do **not** edit `~/.claude/*.ps1` directly — that drifts from the repo. Repo is the source of truth; `deploy.*` promotes it.

## Testing (no test framework — pipe a hook payload to the script)

```powershell
# Windows — ping
'{"message":"test","cwd":"C:/x/proj"}' | & .\windows\notify-discord.ps1 -Event Notification -UserId YOUR_ID
# Windows — activity (Kind = UserPrompt|SubagentStart|SubagentStop|Workflow|Message)
'{"final":true,"delta":"hi","cwd":"C:/x/proj"}' | & .\windows\notify-discord-activity.ps1 -Kind Message
```
```bash
# macOS/Linux (Git Bash works on Windows too, but jq must be installed)
echo '{"message":"test"}' | bash macos-linux/notify-discord.sh Notification YOUR_ID
echo '{"final":true,"delta":"hi"}' | bash macos-linux/notify-discord-activity.sh Message
```
Build test payloads with `jq -nc --arg ...` rather than hand-writing JSON (hand-written Windows paths like `C:\Users` are invalid JSON and produce misleading failures). Discord returns **HTTP 204** on success; an embed posts only if the body is valid — verify with a checked POST when in doubt. Real captured payloads accumulate in `~/.claude/discord_activity_debug.jsonl` (the activity script self-logs every raw stdin) — read it to see the true field shapes for an event.

## How the scripts get their data (requires reading across files / external state)

- **Webhook URLs**: read at runtime from `~/.claude/discord_webhook.txt` and `~/.claude/discord_activity_webhook.txt`. Never embedded in scripts — that's why nothing here is secret.
- **Usage %**: `GET https://api.anthropic.com/api/oauth/usage` (the same undocumented endpoint `/usage` uses) with the OAuth token from `~/.claude/.credentials.json` (Linux/Windows) or the macOS login Keychain (`security find-generic-password -s "Claude Code-credentials" -w`). Headers: `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`. Response: `five_hour`/`seven_day` `{utilization, resets_at}`. All usage code is fail-safe — returns null and the embed shows "live usage unavailable". The activity feed also shows the 5-hour % in each embed footer, **cached ~60s** in `~/.claude/discord_usage_cache.json` so high-frequency events (`MessageDisplay`) don't hit the API every time.
- **Per-prompt token count**: parsed from the session transcript JSONL at `~/.claude/projects/<sanitized-cwd>/*.jsonl` (sum of `input+output+cache_creation` for assistant turns since the last human message; cache reads excluded by `$IncludeCacheReads`).
- **Subagent details** (activity feed): `SubagentStop` payload provides `agent_transcript_path`, `last_assistant_message`, `effort.level`, and `background_tasks[]` (parent workflow). Model + tool tally are read from the agent's own transcript (`<session>/subagents/[workflows/wf_*/]agent-<id>.jsonl`). `SubagentStart` has no effort/transcript yet.
- **`MessageDisplay`**: the text is in the `delta` field (NOT `message_text`); the script only posts when `final` is true (skips streaming partials).
- **Main-agent effort** isn't in any payload — read from `settings.json` `effortLevel` (won't reflect a live `/effort`/fast-mode override).

## Platform gotchas (these caused real bugs — keep them)

- **bash POST must use stdin**: `printf '%s' "$BODY" | curl ... --data-binary @-`. Passing the body as a command-line arg (`-d "$BODY"`) corrupts multibyte UTF-8 under MSYS/Git Bash → Discord rejects with `50109 invalid JSON`. All JSON is built with `jq` (escaping + the reset-time math via `fromdateiso8601`/`now`).
- **PowerShell 5.1 must stay ASCII-safe**: build emoji / progress-bar glyphs from code points (`[System.Char]::ConvertFromUtf32`, `[char]0x25B0`), never paste literal non-ASCII (5.1 reads BOM-less files in the legacy codepage and corrupts them). Read stdin via an explicit UTF-8 `StreamReader` on `[Console]::OpenStandardInput()` — NOT `$input` / `[Console]::InputEncoding`, which decode in the legacy OEM codepage on 5.1 and garble em-dashes/accents/emoji (an em-dash `—` becomes `ΓÇö`) — and POST the body as UTF-8 bytes.
- **`.gitattributes` forces `*.sh eol=lf`** — CRLF breaks the shebang/scripts on Unix. Don't remove it.
- **Discord embed rules**: activity feed sets `allowed_mentions:{parse:[]}` so it never pings; the ping feed puts `<@id>` in `content` (mentions inside embeds don't trigger notifications). `embeds`/`fields` must serialize as JSON arrays.

## Cross-platform path handling

PowerShell scripts use `$base = if ($HOME) {$HOME} else {$env:USERPROFILE}` then `Join-Path` (no backslash literals) so they also run under `pwsh` on macOS/Linux. bash scripts normalize Windows-style paths (`tr '\\' '/'`) so they can be exercised under Git Bash.

## Secrets

Webhook URLs, OAuth credentials, and per-machine state files are read from `~/.claude/` and are listed in `.gitignore`. The repo is public — keep all real webhook IDs/tokens, Discord user IDs, and emails out of committed files and `settings.example.json` (use the `YOUR_DISCORD_USER_ID` placeholder).
