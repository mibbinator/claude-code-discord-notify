#!/usr/bin/env bash
# notify-discord.sh -- pings Discord when Claude Code is waiting for you, with a rich
# embed showing OFFICIAL usage (the same /api/oauth/usage endpoint /usage uses).
# macOS / Linux version. Requires: bash, curl, jq.
# Usage (from a hook): notify-discord.sh <Stop|Notification> [discord_user_id]
# Reads the hook's JSON payload on stdin.
set -uo pipefail

EVENT="${1:-Stop}"
USER_ID="${2:-}"
CLAUDE_DIR="$HOME/.claude"

WEBHOOK_FILE="$CLAUDE_DIR/discord_webhook.txt"
[ -f "$WEBHOOK_FILE" ] || exit 0
WEBHOOK_URL="$(tr -d '[:space:]' < "$WEBHOOK_FILE")"
[ -n "$WEBHOOK_URL" ] || exit 0
command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

RAW="$(cat || true)"
norm() { printf '%s' "$1" | tr '\\' '/'; }   # tolerate Windows-style paths

CWD="$(printf '%s' "$RAW"   | jq -r '.cwd // empty' 2>/dev/null || true)"
DETAIL="$(printf '%s' "$RAW" | jq -r '.message // empty' 2>/dev/null || true)"
TPATH="$(norm "$(printf '%s' "$RAW" | jq -r '.transcript_path // empty' 2>/dev/null || true)")"
NOTIF_TYPE="$(printf '%s' "$RAW" | jq -r '.notification_type // empty' 2>/dev/null || true)"
if [ -n "$CWD" ]; then PROJECT="$(basename "$CWD")"; else PROJECT="$(basename "$PWD")"; fi

# Ping ONLY when Claude needs you. notification_type is the authoritative signal
# (do NOT grep $DETAIL text -- it is dynamic / localized). Allowed: tool-permission
# prompts (incl. AskUserQuestion and plan-mode, which surface as permission_prompt),
# MCP elicitation dialogs, and idle_prompt -- the ~60s "waiting for your input"
# signal that fires when Claude is finished/stuck and it's your turn. Skipped
# (informational): auth_success, elicitation_complete/response, computer_use_*,
# push_notification. (For hard-blocks-only, drop idle_prompt below AND from the
# matcher.) Stop is not wired (turn-end != needs-input); defense-in-depth.
if [ "$EVENT" = "Notification" ] && [ -n "$NOTIF_TYPE" ]; then
  case "$NOTIF_TYPE" in
    permission_prompt|worker_permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog) ;;
    *) exit 0 ;;
  esac
fi

# --- tokens used by the current prompt (since the last human message) -------
PROMPT_TOKENS=0
if [ -n "$TPATH" ] && [ -f "$TPATH" ]; then
  PROMPT_TOKENS="$(jq -s '
    ([ to_entries[]
       | select(.value.type=="user"
           and ((.value.message.content|type)=="string"
                or (((.value.message.content|type)=="array") and (.value.message.content|any(.type=="text")))))
       | .key ] | last) as $lh
    | ($lh // -1) as $lh
    | [ to_entries[] | select(.key > $lh) | .value
        | select(.type=="assistant" and (.message.usage != null)) | .message.usage
        | ((.input_tokens//0)+(.output_tokens//0)+(.cache_creation_input_tokens//0)) ] | add // 0
  ' "$TPATH" 2>/dev/null || echo 0)"
fi
fmt_tokens() { awk -v n="$1" 'BEGIN{ if(n>=1000000) printf "%.1fM",n/1000000; else if(n>=1000) printf "%.1fK",n/1000; else printf "%d",n }'; }
PROMPT_FMT="$(fmt_tokens "$PROMPT_TOKENS")"

# --- daily message counter ("#N", resets each day) --------------------------
COUNT_FILE="$CLAUDE_DIR/discord_notify_count.txt"
TODAY="$(date +%Y-%m-%d)"
COUNT=1
if [ -f "$COUNT_FILE" ]; then
  read -r d n < "$COUNT_FILE" || true
  if [ "${d:-}" = "$TODAY" ] && [ -n "${n:-}" ]; then COUNT=$((n + 1)); fi
fi
printf '%s %s' "$TODAY" "$COUNT" > "$COUNT_FILE" 2>/dev/null || true

# --- official usage (same endpoint /usage uses) -----------------------------
# Token: Linux -> ~/.claude/.credentials.json ; macOS -> login Keychain.
get_token() {
  local cred="$CLAUDE_DIR/.credentials.json"
  if [ -f "$cred" ]; then
    jq -r '.claudeAiOauth.accessToken // empty' "$cred" 2>/dev/null
  elif [ "$(uname -s)" = "Darwin" ]; then
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
      | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
  fi
}
USAGE_JSON="null"
TOKEN="$(get_token || true)"
if [ -n "${TOKEN:-}" ]; then
  resp="$(curl -sf -m 8 'https://api.anthropic.com/api/oauth/usage' \
    -H "Authorization: Bearer $TOKEN" -H 'anthropic-beta: oauth-2025-04-20' \
    -H 'anthropic-version: 2023-06-01' -H 'User-Agent: claude-discord-usage-hook' 2>/dev/null || true)"
  if [ -n "$resp" ] && printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then USAGE_JSON="$resp"; fi
fi

# --- presentation ------------------------------------------------------------
FOLDER="📁"
if [ "$EVENT" = "Notification" ]; then
  GLYPH="🔔"; COLOR=15844367
  case "$NOTIF_TYPE" in
    *permission_prompt) TITLE="$GLYPH  Needs your permission" ;;
    *)                  TITLE="$GLYPH  Needs your input" ;;
  esac
  DESC="${DETAIL:-Claude is waiting for your input.}"
else
  GLYPH="✅"; COLOR=3066993
  TITLE="$GLYPH  Turn complete"
  DESC="Claude finished its turn -- waiting for your reply."
fi
DATESTR="$(date +"%a %b %d, %Y  %I:%M %p")"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# --- build embed + send (all escaping/maths handled by jq) ------------------
BODY="$(jq -n \
  --arg title "$TITLE" --argjson color "$COLOR" --arg desc "$DESC" \
  --arg project "$PROJECT" --arg prompt "$PROMPT_FMT" --argjson count "$COUNT" \
  --arg datestr "$DATESTR" --arg ts "$TS" --arg folder "$FOLDER" \
  --arg userId "$USER_ID" --argjson usage "$USAGE_JSON" '
  def bar($p):
    (($p/10)|round) as $f0 | (if $f0<0 then 0 elif $f0>10 then 10 else $f0 end) as $f
    | reduce range(0;10) as $i (""; . + (if $i < $f then "▰" else "▱" end));
  def resetin($iso):
    if ($iso == null or $iso == "") then "" else
      ($iso | sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z"))
      | (try fromdateiso8601 catch null) as $t
      | if $t == null then "" else
          ((($t - now) | if . < 0 then 0 else . end)) as $r
          | (($r/3600)|floor) as $h | ((($r%3600)/60)|floor) as $m
          | if $h > 0 then "\($h)h \($m)m" else "\($m)m" end
        end
    end;
  ( [ {name:"This prompt", value:($prompt + " tok"), inline:true} ]
    + (if $usage then
         [ {name:"5h resets in", value: resetin($usage.five_hour.resets_at), inline:true},
           {name:"Weekly", value: (($usage.seven_day.utilization // 0)|round|tostring) + "%", inline:true} ]
       else [] end) ) as $fields
  | ( if $usage then
        (($usage.five_hour.utilization // 0)|round) as $p5
        | $desc + "\n\n" + bar($p5) + "  **" + ($p5|tostring) + "%**  used (5h window)"
      else $desc + "\n\n_live usage unavailable_" end ) as $fulldesc
  | { embeds: [ {
        color: $color,
        author: { name: ($folder + "  " + $project) },
        title: $title,
        description: $fulldesc,
        fields: $fields,
        footer: { text: ("#" + ($count|tostring) + "  -  " + $datestr) },
        timestamp: $ts
      } ],
      allowed_mentions: (if $userId == "" then {parse:[]} else {users:[$userId]} end)
    }
  + (if $userId == "" then {} else {content: ("<@" + $userId + ">")} end)
')"

printf '%s' "$BODY" | curl -sf -m 10 -X POST -H 'Content-Type: application/json' --data-binary @- "$WEBHOOK_URL" >/dev/null 2>&1 || true
exit 0
