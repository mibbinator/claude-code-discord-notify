#!/usr/bin/env bash
# notify-discord-usage.sh -- posts a Discord embed every time OFFICIAL usage
# crosses to a new whole percent (~"every 1% used"), for the 5h + weekly windows.
# Silent by default; @-mentions the user when a crossing passes a milestone
# (25/50/80/90/100%) on EITHER window. When a window RESETS it posts a separate,
# highly-visible pinged message per window (5h and weekly independently), and
# distinguishes a normal scheduled rollover from a MANUAL reset Anthropic applies
# to everyone early (detected when usage drops while the prior reset time is still
# in the future). Reads the official /api/oauth/usage data (the same endpoint
# /usage uses), throttled to at most one API call per 5 min (cached), and
# persists the last posted % + reset times between runs.
# macOS / Linux version. Requires: bash, curl, jq.
# Usage (from a hook): notify-discord-usage.sh [discord_user_id]
# Reads the hook's JSON payload on stdin (only used for the project name).
set -uo pipefail

USER_ID="${1:-}"
CLAUDE_DIR="$HOME/.claude"
MILESTONES="25 50 80 90 100"

WEBHOOK_FILE="$CLAUDE_DIR/discord_usage_webhook.txt"
[ -f "$WEBHOOK_FILE" ] || exit 0
WEBHOOK_URL="$(tr -d '[:space:]' < "$WEBHOOK_FILE")"
[ -n "$WEBHOOK_URL" ] || exit 0
command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

RAW="$(cat || true)"
CWD="$(printf '%s' "$RAW" | jq -r '.cwd // empty' 2>/dev/null || true)"
if [ -n "$CWD" ]; then PROJECT="$(basename "$CWD")"; else PROJECT="$(basename "$PWD")"; fi

# --- official usage (same endpoint /usage uses) -----------------------------
get_token() {
  local cred="$CLAUDE_DIR/.credentials.json"
  if [ -f "$cred" ]; then
    jq -r '.claudeAiOauth.accessToken // empty' "$cred" 2>/dev/null
  elif [ "$(uname -s)" = "Darwin" ]; then
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
      | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
  fi
}
# Throttle: hit the usage API at most once per 5 min. PostToolUse fires on every
# tool, so an un-throttled fetch would call the API dozens of times per turn (and
# can get rate-limited). Reuse a cached fetch within the TTL; crossings/resets are
# detected at up-to-5-min granularity.
CACHE_FILE="$CLAUDE_DIR/discord_usage_throttle.json"
TTL=300
NOW="$(date +%s)"
USAGE_JSON="null"
if [ -f "$CACHE_FILE" ]; then
  FETCHED="$(jq -r '.fetched_at // 0' "$CACHE_FILE" 2>/dev/null || echo 0)"
  if [ -n "$FETCHED" ] && [ $(( NOW - FETCHED )) -lt "$TTL" ] 2>/dev/null \
     && jq -e '.five_hour and .seven_day' "$CACHE_FILE" >/dev/null 2>&1; then
    USAGE_JSON="$(cat "$CACHE_FILE")"   # fresh enough -- reuse, no API call
  fi
fi
if [ "$USAGE_JSON" = "null" ]; then
  TOKEN="$(get_token || true)"
  if [ -n "${TOKEN:-}" ]; then
    resp="$(curl -sf -m 8 'https://api.anthropic.com/api/oauth/usage' \
      -H "Authorization: Bearer $TOKEN" -H 'anthropic-beta: oauth-2025-04-20' \
      -H 'anthropic-version: 2023-06-01' -H 'User-Agent: claude-discord-usage-hook' 2>/dev/null || true)"
    if [ -n "$resp" ] && printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then
      USAGE_JSON="$resp"
      printf '%s' "$resp" | jq --argjson now "$NOW" \
        '{fetched_at:$now, five_hour:{utilization:.five_hour.utilization, resets_at:.five_hour.resets_at}, seven_day:{utilization:.seven_day.utilization, resets_at:.seven_day.resets_at}}' \
        > "$CACHE_FILE" 2>/dev/null || true
    fi
  fi
fi
[ "$USAGE_JSON" = "null" ] && exit 0   # API failed and no fresh cache -> do nothing

CUR5="$(printf '%s' "$USAGE_JSON" | jq -r '(.five_hour.utilization // 0) | floor')"
CUR7="$(printf '%s' "$USAGE_JSON" | jq -r '(.seven_day.utilization // 0) | floor')"

# --- last posted state ------------------------------------------------------
STATE_FILE="$CLAUDE_DIR/discord_usage_pct_state.json"
PREV5=-1; PREV7=-1; PREVR5=""; PREVR7=""
if [ -f "$STATE_FILE" ]; then
  PREV5="$(jq -r '.five_hour // -1' "$STATE_FILE" 2>/dev/null || echo -1)"
  PREV7="$(jq -r '.seven_day // -1' "$STATE_FILE" 2>/dev/null || echo -1)"
  PREVR5="$(jq -r '.five_hour_resets_at // ""' "$STATE_FILE" 2>/dev/null || echo "")"
  PREVR7="$(jq -r '.seven_day_resets_at // ""' "$STATE_FILE" 2>/dev/null || echo "")"
fi
R5_ISO="$(printf '%s' "$USAGE_JSON" | jq -r '.five_hour.resets_at // ""')"
R7_ISO="$(printf '%s' "$USAGE_JSON" | jq -r '.seven_day.resets_at // ""')"

# Crossing = a window advanced to a higher whole percent. A drop = that window
# reset (each window accumulates monotonically, then resets to ~0 at its
# boundary). Persist the new floors + reset times regardless before deciding.
CROSSED5=0; CROSSED7=0; RESET5=0; RESET7=0; FIRSTRUN=0
[ "$PREV5" -ge 0 ] 2>/dev/null && [ "$CUR5" -gt "$PREV5" ] 2>/dev/null && CROSSED5=1
[ "$PREV7" -ge 0 ] 2>/dev/null && [ "$CUR7" -gt "$PREV7" ] 2>/dev/null && CROSSED7=1
[ "$PREV5" -ge 0 ] 2>/dev/null && [ "$CUR5" -lt "$PREV5" ] 2>/dev/null && RESET5=1
[ "$PREV7" -ge 0 ] 2>/dev/null && [ "$CUR7" -lt "$PREV7" ] 2>/dev/null && RESET7=1
[ "$PREV5" -lt 0 ] 2>/dev/null && [ "$PREV7" -lt 0 ] 2>/dev/null && FIRSTRUN=1

jq -n --argjson c5 "$CUR5" --argjson c7 "$CUR7" --arg r5 "$R5_ISO" --arg r7 "$R7_ISO" \
  '{five_hour:$c5,seven_day:$c7,five_hour_resets_at:$r5,seven_day_resets_at:$r7}' > "$STATE_FILE" 2>/dev/null || true

# First ever run just establishes the baseline -- no post.
[ "$FIRSTRUN" -eq 1 ] && exit 0
{ [ "$RESET5" -eq 0 ] && [ "$RESET7" -eq 0 ] && [ "$CROSSED5" -eq 0 ] && [ "$CROSSED7" -eq 0 ]; } && exit 0

NL=$'\n'
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
DATESTR="$(date +"%a %b %d, %Y  %I:%M %p")"

# --- helpers (jq-backed formatting; mirrors notify-discord-usage.ps1) -------
crossed_milestone() { local old="$1" new="$2" m; for m in $MILESTONES; do if [ "$old" -lt "$m" ] && [ "$new" -ge "$m" ]; then echo 1; return; fi; done; echo 0; }
bar()       { jq -rn --argjson p "$1" '(($p/10)|round) as $f0 | (if $f0<0 then 0 elif $f0>10 then 10 else $f0 end) as $f | reduce range(0;10) as $i (""; . + (if $i < $f then "▰" else "▱" end))'; }
resetin()   { jq -rn --arg iso "$1" 'if ($iso=="") then "" else ($iso|sub("\\.[0-9]+";"")|sub("\\+00:00$";"Z")) | (try fromdateiso8601 catch null) as $t | if $t==null then "" else ((($t-now)|if .<0 then 0 else . end)) as $r | (($r/3600)|floor) as $h | ((($r%3600)/60)|floor) as $m | if $h>0 then "\($h)h \($m)m" else "\($m)m" end end end'; }
resetinwk() { jq -rn --arg iso "$1" 'if ($iso=="") then "" else ($iso|sub("\\.[0-9]+";"")|sub("\\+00:00$";"Z")) | (try fromdateiso8601 catch null) as $t | if $t==null then "" else ((($t-now)|if .<0 then 0 else . end)) as $r | (($r/86400)|floor) as $d | ((($r%86400)/3600)|floor) as $h | ((($r%3600)/60)|floor) as $m | if $d>0 then "\($d)d \($h)h" elif $h>0 then "\($h)h \($m)m" else "\($m)m" end end end'; }
winline()   { if [ "$4" -eq 1 ] && [ $(( $3 - $2 )) -gt 1 ]; then printf '**%s%% → %s%%**  %s' "$2" "$3" "$1"; else printf '**%s%%**  %s' "$3" "$1"; fi; }
# "manual" if the previously-known reset time is still >5min in the future when
# usage drops (Anthropic cleared the limit early for everyone); else scheduled.
reset_kind() {
  [ -z "$1" ] && { echo scheduled; return; }
  local rem; rem="$(jq -rn --arg iso "$1" '($iso|sub("\\.[0-9]+";"")|sub("\\+00:00$";"Z")) | (try fromdateiso8601 catch null) as $t | if $t==null then -1 else ($t - now) end' 2>/dev/null || echo -1)"
  awk -v r="$rem" 'BEGIN{ if (r>300) print "manual"; else print "scheduled" }'
}
post_embed() { # $1=title $2=desc $3=color $4=fields_json $5=ping(0/1)
  local body
  body="$(jq -n --arg title "$1" --arg desc "$2" --argjson color "$3" --argjson fields "$4" --argjson ping "$5" \
    --arg project "$PROJECT" --arg userId "$USER_ID" --arg datestr "$DATESTR" --arg ts "$TS" '
    { embeds: [ { color:$color, author:{name:("📁  "+$project)}, title:$title, description:$desc, fields:$fields, footer:{text:$datestr}, timestamp:$ts } ],
      allowed_mentions: (if ($ping==1 and $userId!="") then {users:[$userId]} else {parse:[]} end) }
    + (if ($ping==1 and $userId!="") then {content:("<@"+$userId+">")} else {} end)')"
  printf '%s' "$body" | curl -sf -m 10 -X POST -H 'Content-Type: application/json' --data-binary @- "$WEBHOOK_URL" >/dev/null 2>&1 || true
}

# --- resets: one separate, highly-visible message per window ----------------
if [ "$RESET5" -eq 1 ]; then
  BAR5="$(bar "$CUR5")"
  if [ "$(reset_kind "$PREVR5")" = "manual" ]; then
    T="⚡  ANTHROPIC RESET THE 5-HOUR LIMIT"
    D="🎉 **Anthropic just cleared the 5-hour limit early for everyone** -- you're back to **${CUR5}%** ahead of schedule!${NL}${NL}${BAR5}  **${CUR5}%** used (5h window)"
    C=16766720
  else
    T="🔄  5-HOUR LIMIT RESET"
    D="🟢 Your **5-hour** window just rolled over -- back to **${CUR5}%**. Fresh window!${NL}${NL}${BAR5}  **${CUR5}%** used (5h window)"
    C=5763719
  fi
  RN="$(resetin "$R5_ISO")"
  if [ -n "$RN" ]; then F="$(jq -n --arg v "$RN" '[{name:"Next 5h reset in",value:$v,inline:true}]')"; else F="[]"; fi
  post_embed "$T" "$D" "$C" "$F" 1
fi
if [ "$RESET7" -eq 1 ]; then
  BAR7="$(bar "$CUR7")"
  if [ "$(reset_kind "$PREVR7")" = "manual" ]; then
    T="⚡  ANTHROPIC RESET THE WEEKLY LIMIT"
    D="🎉 **Anthropic just cleared the weekly limit early for everyone** -- you're back to **${CUR7}%** ahead of schedule!${NL}${NL}${BAR7}  **${CUR7}%** used (weekly)"
    C=16766720
  else
    T="🔄  WEEKLY LIMIT RESET"
    D="🟢 Your **weekly** window just rolled over -- back to **${CUR7}%**. Fresh window!${NL}${NL}${BAR7}  **${CUR7}%** used (weekly)"
    C=5763719
  fi
  RN="$(resetinwk "$R7_ISO")"
  if [ -n "$RN" ]; then F="$(jq -n --arg v "$RN" '[{name:"Next weekly reset in",value:$v,inline:true}]')"; else F="[]"; fi
  post_embed "$T" "$D" "$C" "$F" 1
fi

# --- routine 1% crossing update (windows that climbed, not the ones reset) --
if { [ "$CROSSED5" -eq 1 ] && [ "$RESET5" -eq 0 ]; } || { [ "$CROSSED7" -eq 1 ] && [ "$RESET7" -eq 0 ]; }; then
  L5="$(winline "used (5h window)" "$PREV5" "$CUR5" "$CROSSED5")"
  L7="$(winline "used (weekly)" "$PREV7" "$CUR7" "$CROSSED7")"
  D="$(bar "$CUR5")  ${L5}${NL}$(bar "$CUR7")  ${L7}"
  CPING=0
  { [ "$CROSSED5" -eq 1 ] && [ "$RESET5" -eq 0 ] && [ "$(crossed_milestone "$PREV5" "$CUR5")" -eq 1 ]; } && CPING=1
  { [ "$CROSSED7" -eq 1 ] && [ "$RESET7" -eq 0 ] && [ "$(crossed_milestone "$PREV7" "$CUR7")" -eq 1 ]; } && CPING=1
  C=3447003
  if [ "$CPING" -eq 1 ]; then
    if [ "$CUR5" -ge 100 ] || [ "$CUR7" -ge 100 ]; then C=15158332; else C=15844367; fi
  fi
  F="$(jq -n --arg a "$(resetin "$R5_ISO")" --arg b "$(resetinwk "$R7_ISO")" '[{name:"5h resets in",value:$a,inline:true},{name:"Weekly resets in",value:$b,inline:true}] | map(select(.value!=""))')"
  post_embed "📊  Usage update" "$D" "$C" "$F" "$CPING"
fi

exit 0
