# cchess-infra

Hosting for [cchess-be](../cchess-be) on one VPS, using Docker Compose:

```
internet ──443/80──▶ caddy ──▶ api (cchess-be) ──▶ postgres
                     (TLS)                          ▲
                                         backup ────┘ nightly pg_dump (+ off-site copy)
```

One box is all the backend can use. It keeps games, clocks and the seek
queue in process memory, and its optional worker sharding goes over Node's
own cluster IPC, so it runs as exactly one process on one host. See
cchess-be's CLAUDE.md for details. [The November 2026 hosting report](docs/reports/2026-11-hosting.md)
covers what was tested, what's missing, and costs.

## What's here

| File | What it does |
|---|---|
| `compose.yaml` | The production stack: `caddy`, `postgres`, `migrate` (one-shot), `api`, `backup`, and `redis` (only under the `cluster` profile) |
| `caddy/Caddyfile` | HTTPS for `$DOMAIN` (Let's Encrypt, or Caddy's own CA when `CADDY_TLS=internal`), proxying to the api, WebSockets included |
| `.env.example` | Every setting. The real `.env` lives only on the server |
| `backup/` | The backup image: `backup.sh` (pg_dump, retention, optional rclone upload), `restore.sh` |
| `provision/cloud-init.yaml` | A fresh Ubuntu 24.04 VPS: deploy user, firewall, updates, Docker |
| `scripts/gen-secrets.sh` | Makes `.env`, generating the DB password and JWT secrets |
| `scripts/deploy.sh` | Builds the api image for the server's CPU, ships it over ssh, restarts |
| `docs/reports/` | Dated reports: what was tested, measured and found, as of each one's date |
| `test/` | `run-local.sh` runs the whole stack in Docker here and smoke-tests it; `run-remote.sh` smoke-tests a deployed server; `static-checks.sh` |

## Setting up a server

1. Create an Ubuntu 24.04 VPS (1 vCPU and 512 MiB is enough to start: see
   the [hosting report's](docs/reports/2026-11-hosting.md) load test). Paste
   `provision/cloud-init.yaml` as its user data, with your SSH public key in
   place of the placeholder.
2. Point the API's DNS name (an `A`/`AAAA` record) at the server's IP.
3. Make the server's `.env`, then set `DOMAIN` and `CADDY_TLS` (your email,
   for Let's Encrypt) in it, and the `RCLONE_*` lines to keep backups off
   the box too:
   ```sh
   rsync -a --relative .env.example scripts/gen-secrets.sh deploy@<server>:/opt/cchess/
   ssh deploy@<server> /opt/cchess/scripts/gen-secrets.sh
   ssh deploy@<server> nano /opt/cchess/.env
   ```
4. From your machine: `scripts/deploy.sh deploy@<server>`.
5. Build the app with `EXPO_PUBLIC_SERVER_URL=https://<domain>` (see
   cchess's `src/network/env.ts`).

## Deploying

```sh
scripts/deploy.sh deploy@api.example.com
```

The script:

1. builds cchess-be (from `../cchess-be`, or `$CCHESS_BE_DIR`) for the
   server's architecture. It refuses uncommitted changes, which would ship
   under a commit that doesn't hold them; `ALLOW_DIRTY=1` ships them to a
   test server anyway, tagged `<commit>-dirty`;
2. loads it there as `cchess-be:<commit>`, and retags that as
   `cchess-be:current`;
3. copies `compose.yaml`, `caddy/` and `backup/` across, runs
   `docker compose up -d --wait`, and has Caddy reload its config;
4. removes all but the image just deployed and the 3 newest before it
   (`KEEP_IMAGES`), so a small disk doesn't fill up.

Migrations run first, in `migrate`, before the api starts. A deploy restarts
the api, so games in progress pause for the few seconds it's down. The api
saves the moves it's handling before it exits, and clients reconnect and
rejoin.

**Rolling back:** retag an earlier commit's image and start it again:

```sh
ssh deploy@api.example.com 'docker tag cchess-be:<commit> cchess-be:current && cd /opt/cchess && docker compose up -d --wait'
```

Migrations only go forward, so a rollback across one needs
`migration:revert` first (cchess-be's README).

## Backups

`backup` dumps the database every day at `BACKUP_HOUR` (UTC). It keeps the
newest `BACKUP_KEEP` dumps in the `backups` volume and copies each one to
`RCLONE_REMOTE` when that's set.

```sh
docker compose exec backup backup.sh                 # one now
docker compose exec backup ls -l /backups            # what's there
docker compose stop api                              # restore with the api stopped:
docker compose exec backup restore.sh latest         # its in-memory games would
docker compose start api                             # write over what's restored
```

## Testing

```sh
npm test            # test/run-local.sh: the stack in Docker here, smoke-tested, torn down
KEEP=1 npm test     # ...and left running, on https://localhost:8443
npm run check       # compose config, shellcheck, cloud-init schema - no stack needed
```

`run-local.sh` builds the api from `../cchess-be`. Caddy serves
`localhost` from its own local CA, which the tests trust, so TLS is real.
The tests check:

- HTTPS and the HTTP redirect;
- a guest sign-up, which needs the database and migrations;
- an authenticated Socket.IO WebSocket through Caddy;
- that nothing but Caddy publishes a port;
- that data survives an api restart;
- a backup and restore round trip, and backup retention;
- that the api stops within its grace period.

To run the tests against a deployed server:

```sh
test/run-remote.sh <ssh host> https://<domain>                       # the read-only checks
ALLOW_DESTRUCTIVE=1 test/run-remote.sh cchess-do-sim https://192.168.1.181   # all of them
```

Without `ALLOW_DESTRUCTIVE=1` only the first five run. With it, the api is
restarted and stopped, and a backup is restored over the database: never
on a server with real players. When the server's `CADDY_TLS` is
`internal`, its CA is fetched and trusted for the run.

CI runs the local suite and the static checks (`.github/workflows/test.yml`).
