# cchess-infra

[![Test](https://github.com/chuxmykel/cchess-infra/actions/workflows/test.yml/badge.svg?branch=develop)](https://github.com/chuxmykel/cchess-infra/actions/workflows/test.yml)
![Docker Compose](https://img.shields.io/badge/Docker_Compose-2496ed)
![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04-e95420)

Hosting for [cchess-be](https://github.com/chuxmykel/cchess-be), the backend
of the [cchess](https://github.com/chuxmykel/cchess) chess app: one VPS,
Docker Compose, automatic HTTPS and nightly backups.

```
internet ──443/80──▶ caddy ──▶ api (cchess-be) ──▶ postgres
                     (TLS)                          ▲
                                         backup ────┘ nightly pg_dump (+ off-site copy)
```

**At a glance**

- **One server, for now.** The backend keeps each live game's clock and
  the seek queue in process memory, and shares work between its workers
  over Node's cluster IPC, which stays on one machine. So the api runs on
  one host. Spreading it across several would take backend changes
  (cchess-be's README, under Known limitations), and one small server
  holds a few hundred games at once.
- **Small.** It's tested on a replica of DigitalOcean's smallest
  droplet (1 vCPU, 512 MiB): 200 simultaneous games under a no-thinking-time stress
  test, with a median move of 0.6 s.
- **Deploys between games.** A deploy announces maintenance, which stops
  new live games, and restarts once the ones in progress have finished.
- **Tested end to end.** A local Docker run and a deployed server both get
  the same smoke tests through real TLS: sign-up, an authenticated
  WebSocket, restarts, and a backup-restore round trip.
- **Also the app's e2e backend.** cchess's Maestro suite plays against a
  seeded variant of this stack.

[The November 2026 hosting report](docs/reports/2026-11-hosting.md) covers
what was tested, what's missing, and the costs on each provider.

## Quick start

Docker and Node, with [cchess-be](https://github.com/chuxmykel/cchess-be)
checked out beside this repo:

```sh
npm test            # the whole stack in Docker, smoke-tested, then torn down
KEEP=1 npm test     # ...left running on https://localhost:8443
```

To put it on a server, see [Setting up a server](#setting-up-a-server).

## What's here

| File | What it does |
|---|---|
| `compose.yaml` | The production stack: `caddy`, `postgres`, `migrate` (applies pending migrations on every deploy, then exits), `api`, `backup`, and `redis` (only under the `cluster` profile) |
| `caddy/Caddyfile` | HTTPS for `$DOMAIN` (Let's Encrypt, or Caddy's own CA when `CADDY_TLS=internal`), proxying to the api, WebSockets included |
| `.env.example` | Every setting. The real `.env` lives only on the server |
| `backup/` | The backup image: `backup.sh` (pg_dump, retention, optional rclone upload), `restore.sh` |
| `provision/cloud-init.yaml` | A fresh Ubuntu 24.04 VPS: deploy user, firewall, updates, Docker |
| `scripts/gen-secrets.sh` | Makes `.env`, generating the DB password and JWT secrets you've left blank |
| `scripts/deploy.sh` | Builds the api image for the server's CPU, ships it over ssh, and restarts once no live game is being played |
| `scripts/maintenance.sh` | Maintenance on a server: announce it, wait for the live games to finish, end it |
| `docs/reports/` | Dated reports: what was tested, measured and found, as of each one's date |
| `test/` | `run-local.sh` runs the whole stack in Docker here and smoke-tests it; `run-remote.sh` smoke-tests a deployed server; `static-checks.sh`; `e2e-stack.sh`, the app's e2e backend |
| `compose.e2e.yaml` | The app's e2e backend (with `compose.local.yaml`): the api seeded and published on 127.0.0.1, no Caddy |

## Setting up a server

1. Create an Ubuntu 24.04 VPS (1 vCPU and 512 MiB is enough to start: see
   the [hosting report's](docs/reports/2026-11-hosting.md) load test). Paste
   `provision/cloud-init.yaml` as its user data, with your SSH public key in
   place of the placeholder.
2. Point the API's DNS name (an `A`/`AAAA` record) at the server's IP.
3. Make the server's `.env` on the server, so its secrets never leave it.
   `gen-secrets.sh` fills in the database password and JWT secrets with
   random values, keeping any you've set yourself. Then set `DOMAIN` and
   `CADDY_TLS` (your email, for Let's Encrypt), and the `RCLONE_*` lines to
   keep backups off the box too:
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
2. loads it there as `cchess-be:<commit>`;
3. waits for the live games to finish (below);
4. retags the image as `cchess-be:current`, copies `compose.yaml`,
   `caddy/` and `backup/` across, runs
   `docker compose up -d --wait`, and has Caddy reload its config;
5. removes all but the image just deployed and the 3 newest before it
   (`KEEP_IMAGES`), so a small disk doesn't fill up.

Migrations run first, in `migrate`, before the api starts.

**Rolling back:** retag an earlier commit's image and start it again, after
`scripts/maintenance.sh <host> drain` unless it can't wait:

```sh
ssh deploy@api.example.com 'docker tag cchess-be:<commit> cchess-be:current && cd /opt/cchess && docker compose up -d --wait'
```

Migrations only go forward, so a rollback across one needs
`migration:revert` first (cchess-be's README, under Commands).

### Waiting for the games

A restart takes the api down for a few seconds, and a live game's clock
keeps running through it, so the deploy waits for a moment with no live
game on (`scripts/maintenance.sh drain`):

1. It announces maintenance, to begin `NOTICE_MINUTES` on (5 by default).
   The app shows a banner with that time in games and while seeking, back
   a minute after it's dismissed.
2. From the announcement, no new live game starts: no seeks, live
   challenges or rematches. Players trying are told why, and seeks already
   waiting are dropped. Daily games start and carry on throughout, since a
   restart loses none of them.
3. Once that time has come and the live games in progress have finished,
   however long that takes, the deploy goes on. The new api starts with no maintenance, so new games
   start again at once.

Maintenance, once announced, stays on until a deploy completes it. Stopping
the wait with Ctrl-C, or a deploy failing after it, leaves it on, new live
games still refused: deploy again to finish, or end it by hand.

```sh
NOTICE_MINUTES=15 scripts/deploy.sh deploy@api.example.com   # more notice
FORCE=1 scripts/deploy.sh deploy@api.example.com             # an emergency: restart at once, games or not
```

With `FORCE=1`, the api saves the moves it's handling before it exits, and
clients reconnect and rejoin, but the player to move loses the seconds it
was down.

`scripts/maintenance.sh` does the same on its own, for anything else that
restarts the api:

```sh
scripts/maintenance.sh deploy@api.example.com status     # whether it's on, when it begins, the live games left
scripts/maintenance.sh deploy@api.example.com start 15   # announce it, to begin in 15 minutes
scripts/maintenance.sh deploy@api.example.com drain 15   # ...and wait for that and the live games
scripts/maintenance.sh deploy@api.example.com end        # end it
```

It talks to the api from inside its container, the only place the api
answers it; Caddy refuses `/internal/*` from the internet as well.

## Backups

`backup` dumps the database every day at `BACKUP_HOUR` (UTC). It keeps the
newest `BACKUP_KEEP` dumps in the `backups` volume and copies each one to
`RCLONE_REMOTE` when that's set.

Backups run while the api is up: `pg_dump` reads a consistent snapshot
without blocking anyone.

```sh
docker compose exec backup backup.sh                 # one now
docker compose exec backup ls -l /backups            # what's there
```

A restore is different. The api holds the games in progress in memory, and
would go on writing their moves and clocks over what's restored, so stop it
first:

```sh
docker compose stop api
docker compose exec backup restore.sh latest
docker compose start api
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
- that the maintenance controls answer inside the api's container and
  not through Caddy, and that maintenance announced is shown to the app;
- that data survives an api restart;
- a backup and restore round trip, and backup retention;
- that the api stops within its grace period.

To run the tests against a deployed server:

```sh
test/run-remote.sh <ssh host> https://<domain>                       # the read-only checks
ALLOW_DESTRUCTIVE=1 test/run-remote.sh cchess-do-sim https://192.168.1.181   # all of them
```

Without `ALLOW_DESTRUCTIVE=1` only the read-only checks run. With it, the api is
restarted and stopped, and a backup is restored over the database: never
on a server with real players. When the server's `CADDY_TLS` is
`internal`, its CA is fetched and trusted for the run.

CI runs the local suite and the static checks (`.github/workflows/test.yml`).

## The app's e2e backend

cchess's Maestro suite (its `scripts/e2e/run.sh`, on the iOS Simulator and
the Android emulator) plays against this stack, made for it by
`compose.e2e.yaml`:

```sh
test/e2e-stack.sh up      # build, migrate, seed, and wait for the api
test/e2e-stack.sh check   # the api answers, and e2e_main can sign in
test/e2e-stack.sh logs    # migrate's, seed's and the api's logs
test/e2e-stack.sh down    # stop it, and throw its database away
```

- The api, built from `../cchess-be` (or `$CCHESS_BE_DIR`), is published on
  `127.0.0.1:$E2E_API_PORT` (3100, clear of a dev backend on 3000) - the
  simulator reaches it there, the emulator as `10.0.2.2`. Caddy isn't
  started: a simulator doesn't trust its local CA, and an Android app trusts
  no CA a user added. Nor are backups.
- A `seed` service, run on each `up` after `migrate` and before the api,
  runs cchess-be's seeders with `SEED_E2E=1`: the bots and the e2e accounts and
  games (cchess-be's README, under Testing). It's built from the Dockerfile's
  `build` stage, which has the dev dependencies the seeders' CLI needs.
- Its own project name (`cchess-e2e`) and `test/e2e.env`, so it never
  touches the smoke test's stack, nor a server's.
- Test only: it publishes a port besides Caddy's, which `static-checks.sh`
  refuses in `compose.yaml` (it still checks the overlay parses).

CI brings it up and checks it on every push (the `E2E stack` job).

## Related repos

- [cchess](https://github.com/chuxmykel/cchess): the iOS and Android app
- [cchess-be](https://github.com/chuxmykel/cchess-be): the server this
  deploys
