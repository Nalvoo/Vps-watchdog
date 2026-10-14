# watchdog.sh

A minimal, production-tested health monitor for Node.js / Next.js apps running on a VPS with PM2.

Built for [maybe.hu](https://maybe.hu) - running in production since 2026.

## What it does

Runs every minute via cron. If your app stops responding:

1. Checks whether a deploy is currently in progress (skips if so)
2. Checks MySQL / Redis availability (skips reload if a dependency is down)
3. Runs `pm2 reload` with backoff - by default max 2 attempts per 10 minutes
4. Sends an email alert via [Resend](https://resend.com) if the reload limit is hit
5. Sends a recovery notification when the app comes back up

## Requirements

- bash 4+
- curl
- pm2
- python3 (for JSON-safe email payload)
- Resend account (free tier is fine for alerts)

## Setup

**1. Clone and configure**

```bash
git clone https://github.com/Nalvoo/watchdog-vps.git
cd watchdog-vps
cp .env.example .env
```

Edit the config block at the top of `watchdog.sh`:

```bash
APP_NAME="myapp"
HEALTH_URL="http://127.0.0.1:3000/api/health"
PM2_PROCESS="myapp"
STATE_DIR="/var/www/myapp/shared"
```

For email alerts, either set them directly in the script or export from your `.env`:

```bash
export $(grep -v '^#' .env | xargs)
```

**2. Add to cron**

```bash
crontab -e
```

```
* * * * * /path/to/watchdog.sh >> /dev/null 2>&1
```

The script appends to its own log file (`STATE_DIR/watchdog.log`). No need to redirect output in cron.

**3. Make it executable**

```bash
chmod +x watchdog.sh
```

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `APP_NAME` | `myapp` | Used in log messages and alert subjects |
| `HEALTH_URL` | `http://127.0.0.1:3000/api/health` | URL to check. Expects HTTP 200 or 307. |
| `HEALTH_SECRET` | _(empty)_ | Sent as `X-Health-Token` header if set |
| `PM2_PROCESS` | `myapp` | Name of the PM2 process to reload |
| `PM2_ECOSYSTEM` | _(empty)_ | Path to ecosystem config - fallback if `pm2 reload` fails |
| `STATE_DIR` | `/var/www/myapp/shared` | Where state files and the log are written |
| `DEPLOY_LOCK` | `${STATE_DIR}/deploy.lock` | flock-based lock file created by your deploy script. Leave empty to disable. |
| `STALE_LOCK_MINS` | `20` | Auto-clear the deploy lock if it's older than this |
| `CHECK_MYSQL` | `0` | Set to `1` to check `mysql.service` before reloading |
| `CHECK_REDIS` | `0` | Set to `1` to check `redis-server.service` before reloading |
| `MAX_RELOADS` | `2` | Max reload attempts within `COOLDOWN_SECS` |
| `COOLDOWN_SECS` | `600` | Reload counter resets after this many seconds |
| `RESEND_API_KEY` | _(env)_ | Resend API key. Can be set in `.env`. |
| `ALERT_FROM` | `watchdog@example.com` | Sender address (must be verified in Resend) |
| `ALERT_TO` | _(env)_ | Alert recipient |
| `ALERT_COOLDOWN_SECS` | `1800` | Minimum seconds between alerts |

## Deploy lock integration

If you use a deploy script with `flock`, the watchdog will skip while a deploy is running and auto-clear stale locks:

```bash
# In your deploy.sh:
exec 9>"$LOCK_FILE"
flock -n 9 || exit 1
# ... deploy logic
```

## Health endpoint

Your app needs a `/api/health` endpoint that returns HTTP 200. A minimal Next.js example:

```ts
// app/api/health/route.ts
export async function GET() {
  return Response.json({ status: "ok" })
}
```

For authenticated deep checks (DB + Redis), read the `X-Health-Token` header and gate behind `HEALTH_SECRET`.

## Log format

```
[2026-10-14 03:12:01] [DEGRADED] myapp - HTTP 000
[2026-10-14 03:12:01] [RELOAD] pm2 reload myapp (attempt 1/2)
[2026-10-14 03:13:01] [RECOVERED] myapp - HTTP 200, was: degraded (~1m downtime)
```

Log categories: `OK` · `DEGRADED` · `DEP_DOWN` · `RELOAD` · `COOLDOWN` · `RECOVERED` · `ALERT` · `STALE_LOCK` · `DEPLOY_SKIP`

## License

MIT
