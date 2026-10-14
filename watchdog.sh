#!/usr/bin/env bash
# watchdog.sh - PM2 process health monitor with auto-reload and email alerts
#
# Designed for: Node.js / Next.js apps on a single VPS, managed by PM2.
# Run via cron every minute: * * * * * /path/to/watchdog.sh
#
# Features:
#   - HTTP health check with configurable endpoint
#   - Auto pm2 reload with exponential backoff (configurable max attempts)
#   - Dependency checks: MySQL and/or Redis (optional, skips reload if dep is down)
#   - Deploy lock awareness: skips if a deploy is in progress
#   - Stale lock auto-clear: removes locks that are too old to be real deploys
#   - Email alerts via Resend (deduped, fire-and-forget)
#   - Recovery notifications
#
# State files (auto-created in STATE_DIR):
#   watchdog-health-state   - "ok" | "degraded" | "dep_down"
#   watchdog-last-reload    - "$UNIX_TS $RELOAD_COUNT" (backoff tracking)
#   watchdog-last-alert     - "$UNIX_TS" (alert dedup)

set -euo pipefail

# Configuration
# Edit this block. Everything else is logic.

APP_NAME="myapp"
HEALTH_URL="http://127.0.0.1:3000/api/health"
# Optional: if set, passed as X-Health-Token header (for authenticated /health endpoints)
HEALTH_SECRET="${HEALTH_SECRET:-}"

PM2_PROCESS="myapp"
# Fallback ecosystem config for pm2 start (used if pm2 reload fails)
PM2_ECOSYSTEM=""

STATE_DIR="/var/www/myapp/shared"
LOG_FILE="${STATE_DIR}/watchdog.log"

# Optional: path to a deploy lock file created by your deploy script.
# If the lock is held by an active flock, watchdog skips. Leave empty to disable.
DEPLOY_LOCK="${STATE_DIR}/deploy.lock"
STALE_LOCK_MINS=20

# Dependency checks - set to 1 to enable. If a dep is down, reload is skipped.
CHECK_MYSQL=0
CHECK_REDIS=0

# Reload backoff: allow MAX_RELOADS within COOLDOWN_SECS before giving up.
MAX_RELOADS=2
COOLDOWN_SECS=600

# Alerts: Resend API. Reads from env if not set here.
RESEND_API_KEY="${RESEND_API_KEY:-}"
ALERT_FROM="${ALERT_FROM:-watchdog@example.com}"
ALERT_TO="${ALERT_TO:-}"
ALERT_COOLDOWN_SECS=1800

# Helpers

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
now() { date +%s; }

log() {
  local line="[$(ts)] $*"
  echo "$line" >> "$LOG_FILE"
}

send_alert() {
  local msg="$1"
  [[ -z "$RESEND_API_KEY" || -z "$ALERT_TO" ]] && return 0

  local alert_stamp="${STATE_DIR}/watchdog-last-alert"
  local last=0
  [[ -f "$alert_stamp" ]] && last=$(cat "$alert_stamp" 2>/dev/null || echo 0)
  (( $(now) - last < ALERT_COOLDOWN_SECS )) && return 0

  now > "$alert_stamp"
  log "[ALERT] $msg"

  local subject="[watchdog/${APP_NAME}] ${msg:0:80}"
  local host; host=$(hostname -s 2>/dev/null || echo "server")

  curl -s -X POST "https://api.resend.com/emails" \
    -H "Authorization: Bearer ${RESEND_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"from\": \"${ALERT_FROM}\",
      \"to\": [\"${ALERT_TO}\"],
      \"subject\": $(printf '%s' "$subject" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
      \"text\": $(printf '%s\n\nHost: %s\nTime: %s' "$msg" "$host" "$(ts)" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')
    }" \
    --max-time 10 >/dev/null 2>&1 &
}

# State helpers

HEALTH_STATE_FILE="${STATE_DIR}/watchdog-health-state"
RELOAD_STAMP="${STATE_DIR}/watchdog-last-reload"

read_health_state() {
  PREV_STATE="ok"
  [[ -f "$HEALTH_STATE_FILE" ]] || return 0
  local raw; raw=$(cat "$HEALTH_STATE_FILE" 2>/dev/null) || return 0
  case "$raw" in ok|degraded|dep_down) PREV_STATE="$raw" ;; esac
}

write_health_state() { printf '%s\n' "$1" > "$HEALTH_STATE_FILE"; }

read_reload_stamp() {
  LAST_RELOAD=0; RELOAD_COUNT=0
  [[ -f "$RELOAD_STAMP" ]] || return 0
  local raw; raw=$(cat "$RELOAD_STAMP" 2>/dev/null) || return 0
  local t c
  t=$(awk '{print $1}' <<< "$raw")
  c=$(awk '{print $2}' <<< "$raw")
  [[ "$t" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ ]] || return 0
  LAST_RELOAD=$t; RELOAD_COUNT=$c
}

write_reload_stamp() { printf '%s %s\n' "$1" "$2" > "$RELOAD_STAMP"; }
reset_reload_stamp()  { rm -f "$RELOAD_STAMP"; LAST_RELOAD=0; RELOAD_COUNT=0; }

# Deploy lock

check_deploy_lock() {
  [[ -z "$DEPLOY_LOCK" || ! -f "$DEPLOY_LOCK" ]] && return 0

  if flock -n "$DEPLOY_LOCK" true 2>/dev/null; then
    # Lock file exists but no process holds it - stale
    local age_mins=$(( ( $(now) - $(stat -c %Y "$DEPLOY_LOCK" 2>/dev/null || echo 0) ) / 60 ))
    if (( age_mins >= STALE_LOCK_MINS )); then
      log "[STALE_LOCK] deploy.lock is ${age_mins}m old, removing"
      rm -f "$DEPLOY_LOCK"
      send_alert "Stale deploy lock removed (${age_mins}m old). Check if a deploy crashed."
      return 0
    fi
    log "[DEPLOY_SKIP] lock exists (${age_mins}m), skipping"
    return 1
  fi

  log "[DEPLOY_SKIP] deploy in progress, skipping"
  return 1
}

# Dependency checks

check_deps() {
  DEPS_OK=1
  local down=""

  if (( CHECK_MYSQL )); then
    systemctl is-active mysql.service --quiet 2>/dev/null || { DEPS_OK=0; down+="mysql "; }
  fi
  if (( CHECK_REDIS )); then
    systemctl is-active redis-server.service --quiet 2>/dev/null || { DEPS_OK=0; down+="redis"; }
  fi

  if (( ! DEPS_OK )); then
    log "[DEP_DOWN] ${down% } is down - skipping reload"
    write_health_state "dep_down"
    send_alert "${APP_NAME} degraded - dependency down: ${down% }. Reload skipped."
  fi
}

# Main

mkdir -p "$STATE_DIR"

check_deploy_lock || exit 0

# Health check
CURL_ARGS=(-s -o /dev/null -w "%{http_code}" --max-time 10)
if [[ -n "$HEALTH_SECRET" ]]; then
  CURL_ARGS+=(-H "X-Health-Token: ${HEALTH_SECRET}")
fi

HTTP_STATUS=$(curl "${CURL_ARGS[@]}" "$HEALTH_URL" 2>/dev/null) || HTTP_STATUS="000"

read_health_state

if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "307" ]]; then
  if [[ "$PREV_STATE" != "ok" ]]; then
    local_downtime=""
    if [[ -f "$RELOAD_STAMP" ]]; then
      local t; t=$(awk '{print $1}' "$RELOAD_STAMP" 2>/dev/null) || t=0
      [[ "$t" =~ ^[0-9]+$ && "$t" -gt 0 ]] && \
        local_downtime=" (~$(( ( $(now) - t ) / 60 ))m downtime)"
    fi
    log "[RECOVERED] ${PM2_PROCESS} - HTTP ${HTTP_STATUS}, was: ${PREV_STATE}${local_downtime}"
    send_alert "${APP_NAME} recovered. Was: ${PREV_STATE}.${local_downtime}"
    reset_reload_stamp
  fi
  write_health_state "ok"
  exit 0
fi

log "[DEGRADED] ${PM2_PROCESS} - HTTP ${HTTP_STATUS}"

check_deps
(( DEPS_OK )) || exit 0

write_health_state "degraded"

read_reload_stamp
local_now=$(now)
local_elapsed=$(( local_now - LAST_RELOAD ))

(( local_elapsed >= COOLDOWN_SECS )) && RELOAD_COUNT=0

if (( RELOAD_COUNT >= MAX_RELOADS )); then
  log "[COOLDOWN] ${RELOAD_COUNT}x reload in ${local_elapsed}s, giving up"
  (( local_elapsed < COOLDOWN_SECS )) && \
    send_alert "${APP_NAME} is DOWN. ${RELOAD_COUNT}x auto-reload failed. Manual intervention required. HTTP: ${HTTP_STATUS}"
  exit 0
fi

RELOAD_COUNT=$(( RELOAD_COUNT + 1 ))
write_reload_stamp "$local_now" "$RELOAD_COUNT"

log "[RELOAD] pm2 reload ${PM2_PROCESS} (attempt ${RELOAD_COUNT}/${MAX_RELOADS})"

if ! pm2 reload "$PM2_PROCESS" >> "$LOG_FILE" 2>&1; then
  log "[WARN] pm2 reload failed"
  if [[ -n "$PM2_ECOSYSTEM" ]] && [[ -f "$PM2_ECOSYSTEM" ]]; then
    log "[RELOAD] pm2 start ${PM2_ECOSYSTEM} --only ${PM2_PROCESS}"
    pm2 start "$PM2_ECOSYSTEM" --only "$PM2_PROCESS" >> "$LOG_FILE" 2>&1 || \
      log "[ERROR] pm2 start also failed - manual intervention required"
  fi
fi
