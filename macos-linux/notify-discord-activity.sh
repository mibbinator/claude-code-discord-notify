#!/usr/bin/env bash
# notify-discord-activity.sh -- posts Claude Code ACTIVITY to a SEPARATE Discord
# channel with NO @-mention (info feed only), as rich embeds. macOS / Linux version.
# Requires: bash, curl, jq.  Usage: notify-discord-activity.sh <Kind>
#   Kind = UserPrompt | SubagentStart | SubagentStop | Workflow | Message
# Reads the hook JSON on stdin. Wire one hook per Kind in settings.json.
set -uo pipefail

KIND="${1:-}"
CLAUDE_DIR="$HOME/.claude"

WEBHOOK_FILE="$CLAUDE_DIR/discord_activity_webhook.txt"
[ -f "$WEBHOOK_FILE" ] || exit 0
WEBHOOK_URL="$(tr -d '[:space:]' < "$WEBHOOK_FILE")"
[ -n "$WEBHOOK_URL" ] || exit 0
command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

RAW="$(cat || true)"
[ -n "$KIND" ] || KIND="$(printf '%s' "$RAW" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
norm() { printf '%s' "$1" | tr '\\' '/'; }
jget() { printf '%s' "$RAW" | jq -r "$1 // empty" 2>/dev/null || true; }

# Self-documenting log of raw payloads (safe to delete).
jq -nc --arg at "$(date -u +%FT%TZ)" --arg kind "$KIND" --arg raw "$RAW" \
  '{at:$at,kind:$kind,raw:$raw}' >> "$CLAUDE_DIR/discord_activity_debug.jsonl" 2>/dev/null || true

trunc() { local s="$1" n="$2"; if [ "${#s}" -gt "$n" ]; then printf '%s ...' "${s:0:$n}"; else printf '%s' "$s"; fi; }
fmt_model() {
  local m="$1"; [ -n "$m" ] || { printf ''; return; }
  printf '%s' "$m" \
    | sed -E -e 's/^claude-([a-z]+)-([0-9]+)-([0-9]+).*/\1 \2.\3/' -e 's/^claude-([a-z]+)-([0-9]+)$/\1 \2/' \
    | awk '{ $1=toupper(substr($1,1,1)) substr($1,2); print }'
}
fmt_effort() {
  local e="$1"; [ -n "$e" ] || { printf ''; return; }
  if [ "$e" = "xhigh" ]; then printf 'X-High'; else printf '%s' "$e" | awk '{ print toupper(substr($0,1,1)) substr($0,2) }'; fi
}
agent_task()  { [ -f "$1" ] && head -n 1 "$1" | jq -r 'if (.message.content|type)=="string" then .message.content elif (.message.content|type)=="array" then ([.message.content[]|select(.type=="text")|.text]|join("\n")) else "" end' 2>/dev/null || true; }
agent_model() { [ -f "$1" ] && jq -rs '[.[]|select(.type=="assistant")|.message.model//empty]|last//""' "$1" 2>/dev/null || true; }
agent_tools() { [ -f "$1" ] && jq -rs '[ .[]|select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|.name ] | group_by(.) | map({n:.[0],c:length}) | sort_by(-.c) | map("`\(.n)` x\(.c)") | join("  ")' "$1" 2>/dev/null || true; }
find_agent_tx() { # $1 main transcript_path, $2 agent_id
  local base; base="$(norm "$1")"; base="${base%.jsonl}"
  [ -n "$2" ] && [ -d "$base/subagents" ] && find "$base/subagents" -name "agent-$2.jsonl" 2>/dev/null | head -n 1 || true
}
# Official 5-hour usage %, cached ~60s so the high-frequency activity feed does
# not hit api.anthropic.com on every event. Echoes the integer percent, or ''.
get_usage_pct() {
  local cache="$CLAUDE_DIR/discord_usage_cache.json" now ts token cred resp pct
  now=$(date -u +%s)
  if [ -f "$cache" ]; then
    ts=$(jq -r '.ts // 0' "$cache" 2>/dev/null || echo 0)
    if [ "${ts:-0}" -gt 0 ] && [ $((now - ts)) -lt 60 ]; then
      jq -r '.pct // empty' "$cache" 2>/dev/null || true
      return
    fi
  fi
  cred="$CLAUDE_DIR/.credentials.json"; token=""
  if [ -f "$cred" ]; then
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$cred" 2>/dev/null || true)
  elif [ "$(uname -s)" = "Darwin" ]; then
    token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null || true)
  fi
  pct=""
  if [ -n "$token" ]; then
    resp=$(curl -sf -m 8 'https://api.anthropic.com/api/oauth/usage' -H "Authorization: Bearer $token" -H 'anthropic-beta: oauth-2025-04-20' -H 'anthropic-version: 2023-06-01' -H 'User-Agent: claude-discord-usage-hook' 2>/dev/null || true)
    [ -n "$resp" ] && pct=$(printf '%s' "$resp" | jq -r 'if .five_hour.utilization != null then (.five_hour.utilization|round|tostring) else empty end' 2>/dev/null || true)
  fi
  jq -nc --argjson ts "$now" --arg pct "$pct" '{ts:$ts,pct:$pct}' > "$cache" 2>/dev/null || true
  printf '%s' "$pct"
}

CWD="$(jget '.cwd')"
DIR=""; [ -n "$CWD" ] && DIR="$(basename "$CWD")"

COLOR=9807270; TITLE=""; DESC=""
AGENT_TYPE=""; MODEL=""; EFFORT=""; TOOLS=""; WF=""

case "$KIND" in
  UserPrompt)
    P="$(printf '%s' "$RAW" | jq -r '(.prompt // .user_prompt // .message // .text // .content) // empty | if type=="array" then ([.[]|(.text? // tostring)]|join(" ")) else . end' 2>/dev/null || true)"
    [ -n "$P" ] || exit 0
    COLOR=5793266; TITLE="💬  Your prompt"; DESC="$(trunc "$P" 2000)"
    ;;
  SubagentStart)
    AGENT_TYPE="$(jget '.agent_type // .subagent_type // .agentType')"
    ID="$(jget '.agent_id // .agentId // .id')"
    TX="$(norm "$(jget '.agent_transcript_path')")"; [ -n "$TX" ] || TX="$(find_agent_tx "$(jget '.transcript_path')" "$ID")"
    TASK="$(agent_task "$TX")"
    COLOR=1752220; TITLE="▶  Agent started"
    if [ -n "$TASK" ]; then DESC="$(trunc "$TASK" 1500)"; else DESC="_(task not captured yet)_"; fi
    MODEL="$(fmt_model "$(agent_model "$TX")")"
    ;;
  SubagentStop)
    AGENT_TYPE="$(jget '.agent_type // .subagent_type // .agentType')"
    TX="$(norm "$(jget '.agent_transcript_path')")"; [ -n "$TX" ] || TX="$(find_agent_tx "$(jget '.transcript_path')" "$(jget '.agent_id // .agentId // .id')")"
    RES="$(jget '.last_assistant_message')"
    COLOR=3066993; TITLE="✅  Agent done"
    if [ -n "$RES" ]; then DESC="$(trunc "$RES" 1800)"; else DESC="_(no result captured)_"; fi
    MODEL="$(fmt_model "$(agent_model "$TX")")"
    EFFORT="$(fmt_effort "$(jget '.effort.level')")"
    TOOLS="$(trunc "$(agent_tools "$TX")" 1000)"
    WF="$(trunc "$(printf '%s' "$RAW" | jq -r '(.background_tasks // [])[] | select(.type=="workflow") | "\(.name) -- \(.description) [\(.status)]"' 2>/dev/null | head -n 1)" 1000)"
    ;;
  Workflow)
    RESP="$(printf '%s' "$RAW" | jq -rc '(.tool_response // .tool_output // .tool_result) // empty | if type=="string" then . else tojson end' 2>/dev/null || true)"
    COLOR=15105570; TITLE="⚙  Workflow finished"
    if [ -n "$RESP" ]; then DESC="$(trunc "$RESP" 2000)"; else DESC="_(no result captured)_"; fi
    ;;
  Message)
    FINAL="$(printf '%s' "$RAW" | jq -r 'if has("final") then (.final|tostring) else "true" end' 2>/dev/null || echo true)"
    [ "$FINAL" = "false" ] && exit 0
    MSG="$(printf '%s' "$RAW" | jq -r '(.delta // .message_text // .message // .text // .content) // empty | if type=="array" then ([.[]|(.text? // tostring)]|join("\n")) else . end' 2>/dev/null || true)"
    [ -n "$MSG" ] || exit 0
    COLOR=9807270; TITLE="🤖  Claude"; DESC="$(trunc "$MSG" 2000)"
    MODEL="$(fmt_model "$(agent_model "$(norm "$(jget '.transcript_path')")")")"
    EFFORT="$(fmt_effort "$(jq -r '.effortLevel // empty' "$CLAUDE_DIR/settings.json" 2>/dev/null || true)")"
    ;;
  *)
    TITLE="($KIND)"; DESC="$(trunc "$RAW" 1500)"
    ;;
esac

[ -n "$DESC" ] || [ -n "$AGENT_TYPE$MODEL$EFFORT$TOOLS$WF" ] || exit 0

TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
DATESTR="$(date +"%a %b %d, %Y  %I:%M:%S %p")"
PCT="$(get_usage_pct)"
[ -n "$PCT" ] && DATESTR="$DATESTR  -  ${PCT}% of 5h"

BODY="$(jq -n \
  --argjson color "$COLOR" --arg title "$TITLE" --arg desc "$DESC" \
  --arg dir "$DIR" --arg folder "📁" --arg ts "$TS" --arg datestr "$DATESTR" \
  --arg agentType "$AGENT_TYPE" --arg model "$MODEL" --arg effort "$EFFORT" \
  --arg tools "$TOOLS" --arg wf "$WF" '
  ( [ (if $agentType != "" then {name:"Agent",      value:("`"+$agentType+"`"), inline:true}  else empty end),
      (if $model     != "" then {name:"Model",      value:("`"+$model+"`"),     inline:true}  else empty end),
      (if $effort    != "" then {name:"Effort",     value:$effort,              inline:true}  else empty end),
      (if $tools     != "" then {name:"Tools used", value:$tools,               inline:false} else empty end),
      (if $wf        != "" then {name:"Workflow",   value:$wf,                  inline:false} else empty end) ] ) as $fields
  | { embeds: [ ( { color:$color, title:$title, timestamp:$ts, footer:{text:$datestr} }
                  + (if $desc != "" then {description:$desc} else {} end)
                  + (if $dir  != "" then {author:{name:($folder + "  " + $dir)}} else {} end)
                  + (if ($fields|length) > 0 then {fields:$fields} else {} end) ) ],
      allowed_mentions: {parse: []} }
')"

printf '%s' "$BODY" | curl -sf -m 8 -X POST -H 'Content-Type: application/json' --data-binary @- "$WEBHOOK_URL" >/dev/null 2>&1 || true
exit 0
