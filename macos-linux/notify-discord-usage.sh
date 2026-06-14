#!/usr/bin/env bash
# notify-discord-usage.sh -- posts a Discord embed every time OFFICIAL usage
# crosses to a new whole percent (~"every 1% used"), for the 5h + weekly windows.
# Silent by default; @-mentions the user when a crossing passes a milestone
# (25/50/80/90/100%) on EITHER window. Reads the official /api/oauth/usage data
# (the same endpoint /usage uses) and persists the last posted % between runs.
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
USAGE_JSON="null"
TOKEN="$(get_token || true)"
if [ -n "${TOKEN:-}" ]; then
  resp="$(curl -sf -m 8 'https://api.anthropic.com/api/oauth/usage' \
    -H "Authorization: Bearer $TOKEN" -H 'anthropic-beta: oauth-2025-04-20' \
    -H 'anthropic-version: 2023-06-01' -H 'User-Agent: claude-discord-usage-hook' 2>/dev/null || true)"
  if [ -n "$resp" ] && printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then USAGE_JSON="$resp"; fi
fi
[ "$USAGE_JSON" = "null" ] && exit 0   # can't tell what crossed -> do nothing

CUR5="$(printf '%s' "$USAGE_JSON" | jq -r '(.five_hour.utilization // 0) | floor')"
CUR7="$(printf '%s' "$USAGE_JSON" | jq -r '(.seven_day.utilization // 0) | floor')"

# --- last posted state ------------------------------------------------------
STATE_FILE="$CLAUDE_DIR/discord_usage_pct_state.json"
PREV5=-1; PREV7=-1
if [ -f "$STATE_FILE" ]; then
  PREV5="$(jq -r '.five_hour // -1' "$STATE_FILE" 2>/dev/null || echo -1)"
  PREV7="$(jq -r '.seven_day // -1' "$STATE_FILE" 2>/dev/null || echo -1)"
fi

# Crossing = a window advanced to a higher whole percent. A drop (window reset)
# silently re-baselines. Persist the new floors regardless before deciding.
CROSSED5=0; CROSSED7=0; RESET5=0; RESET7=0; FIRSTRUN=0
[ "$PREV5" -ge 0 ] 2>/dev/null && [ "$CUR5" -gt "$PREV5" ] 2>/dev/null && CROSSED5=1
[ "$PREV7" -ge 0 ] 2>/dev/null && [ "$CUR7" -gt "$PREV7" ] 2>/dev/null && CROSSED7=1
# A window resetting shows up as utilization dropping below the stored value:
# each window accumulates monotonically, then resets to ~0 at its boundary.
[ "$PREV5" -ge 0 ] 2>/dev/null && [ "$CUR5" -lt "$PREV5" ] 2>/dev/null && RESET5=1
[ "$PREV7" -ge 0 ] 2>/dev/null && [ "$CUR7" -lt "$PREV7" ] 2>/dev/null && RESET7=1
ISRESET=0; { [ "$RESET5" -eq 1 ] || [ "$RESET7" -eq 1 ]; } && ISRESET=1
[ "$PREV5" -lt 0 ] 2>/dev/null && [ "$PREV7" -lt 0 ] 2>/dev/null && FIRSTRUN=1

printf '{"five_hour":%s,"seven_day":%s}' "$CUR5" "$CUR7" > "$STATE_FILE" 2>/dev/null || true

# First ever run just establishes the baseline -- no post.
[ "$FIRSTRUN" -eq 1 ] && exit 0
[ "$ISRESET" -eq 0 ] && [ "$CROSSED5" -eq 0 ] && [ "$CROSSED7" -eq 0 ] && exit 0

# --- ping decision ----------------------------------------------------------
# A limit reset always pings; a routine 1% crossing pings only at a milestone.
crossed_milestone() { # $1=old $2=new -> echoes 1 if any milestone in (old,new]
  local old="$1" new="$2" m
  for m in $MILESTONES; do
    if [ "$old" -lt "$m" ] && [ "$new" -ge "$m" ]; then echo 1; return; fi
  done
  echo 0
}
PING=0
[ "$ISRESET" -eq 1 ] && PING=1
[ "$CROSSED5" -eq 1 ] && [ "$(crossed_milestone "$PREV5" "$CUR5")" -eq 1 ] && PING=1
[ "$CROSSED7" -eq 1 ] && [ "$(crossed_milestone "$PREV7" "$CUR7")" -eq 1 ] && PING=1

# --- presentation ------------------------------------------------------------
if [ "$ISRESET" -eq 1 ]; then
  which=""
  [ "$RESET5" -eq 1 ] && which="5h"
  [ "$RESET7" -eq 1 ] && { [ -n "$which" ] && which="$which + weekly" || which="weekly"; }
  TITLE="🔄  $which limit reset"
  COLOR=3066993   # green -- fresh window
else
  TITLE="📊  Usage update"
  COLOR=3447003   # blurple for routine 1% updates
  if [ "$PING" -eq 1 ]; then
    if [ "$CUR5" -ge 100 ] || [ "$CUR7" -ge 100 ]; then COLOR=15158332; else COLOR=15844367; fi
  fi
fi
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
DATESTR="$(date +"%a %b %d, %Y  %I:%M %p")"

BODY="$(jq -n \
  --argjson color "$COLOR" --arg project "$PROJECT" --arg userId "$USER_ID" --arg title "$TITLE" \
  --argjson usage "$USAGE_JSON" --arg datestr "$DATESTR" --arg ts "$TS" \
  --argjson prev5 "$PREV5" --argjson cur5 "$CUR5" --argjson crossed5 "$CROSSED5" \
  --argjson prev7 "$PREV7" --argjson cur7 "$CUR7" --argjson crossed7 "$CROSSED7" \
  --argjson ping "$PING" '
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
  # Weekly reset can be days out -- format in days + hours (e.g. "3d 1h").
  def resetinwk($iso):
    if ($iso == null or $iso == "") then "" else
      ($iso | sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z"))
      | (try fromdateiso8601 catch null) as $t
      | if $t == null then "" else
          ((($t - now) | if . < 0 then 0 else . end)) as $r
          | (($r/86400)|floor) as $d | ((($r%86400)/3600)|floor) as $h | ((($r%3600)/60)|floor) as $m
          | if $d > 0 then "\($d)d \($h)h" elif $h > 0 then "\($h)h \($m)m" else "\($m)m" end
        end
    end;
  def winline($label; $old; $new; $crossed):
    if ($crossed == 1 and ($new - $old) > 1)
    then "**\($old)% → \($new)%**  " + $label
    else "**\($new)%**  " + $label end;
  ( bar($cur5) + "  " + winline("used (5h window)"; $prev5; $cur5; $crossed5)
    + "\n" + bar($cur7) + "  " + winline("used (weekly)"; $prev7; $cur7; $crossed7) ) as $desc
  | ( [ {name:"5h resets in", value: resetin($usage.five_hour.resets_at), inline:true},
        {name:"Weekly resets in", value: resetinwk($usage.seven_day.resets_at), inline:true} ]
      | map(select(.value != "")) ) as $fields
  | { embeds: [ {
        color: $color,
        author: { name: ("📁  " + $project) },
        title: $title,
        description: $desc,
        fields: $fields,
        footer: { text: $datestr },
        timestamp: $ts
      } ],
      allowed_mentions: (if ($ping == 1 and $userId != "") then {users:[$userId]} else {parse:[]} end)
    }
  + (if ($ping == 1 and $userId != "") then {content: ("<@" + $userId + ">")} else {} end)
')"

printf '%s' "$BODY" | curl -sf -m 10 -X POST -H 'Content-Type: application/json' --data-binary @- "$WEBHOOK_URL" >/dev/null 2>&1 || true
exit 0
