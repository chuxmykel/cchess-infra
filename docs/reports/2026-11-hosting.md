# cchess hosting: status, gaps and costs

*Written 2026-11-10; the droplet-replica test added 2026-11-14. Prices exclude VAT; sources are at the end.*

## Summary

- **Where it runs:** cchess-be runs on **one VPS with Docker Compose**: Caddy
  for HTTPS, the API, Postgres 18, and a nightly backup job.
- **What's tested:** the whole stack, locally in Docker and on a replica of
  DigitalOcean's **$4 droplet** (1 vCPU, 512 MiB, 10 GiB) provisioned by our
  cloud-init and deployed by `deploy.sh`. 9 smoke tests pass on both,
  through real TLS. The static checks pass.
- **How the $4 box copes:** fine for a personal project. Under a stress test
  with no thinking time between moves, it handled **200 simultaneous games
  (400 players)** with a median move of 0.6 s. At **400 games (800 players)**
  it ran out of memory and slowed to a crawl, without crashing.
- **What isn't tested:** a real Let's Encrypt certificate (it needs a public
  domain), off-site backup uploads, and the CI workflow.
- **Cost:** **$4-5/month** on DigitalOcean's smallest droplet, about
  **€7-8/month (~$8-9)** on Hetzner in the EU, or **$12-15/month** for 2 GB on
  a US provider. The AWS setup considered first (Fargate,
  ALB and RDS) would be about **$60-70/month**.

## Why one VPS

The backend can only use one machine anyway:

- It keeps games in progress, clocks and the seek queue in process memory.
- Its worker sharding routes between processes over Node's own cluster IPC.

So it must run as exactly one process on one host. Managed cloud services
mostly charge for what this app can't use: several instances, load
balancing and failover. A single box with Postgres beside it fits, at a
fraction of the price.

## What was built

| Piece | State |
|---|---|
| cchess-be `Dockerfile` + `.dockerignore` (branch `chore/dockerfile`) | Builds (371 MB image); boots against Postgres |
| `compose.yaml`: caddy, postgres, migrate, api, backup, redis (opt-in) | Runs; healthchecks pass |
| Caddy: HTTPS, HTTP→HTTPS redirect, WebSocket proxying | Tested with Caddy's local CA, on `localhost` and on an IP address; not with Let's Encrypt |
| Backups: pg_dump nightly, retention, optional rclone off-site | Backup, restore and retention tested; off-site upload not tested |
| `provision/cloud-init.yaml` | Booted on the $4-droplet replica: done in 112 s, no errors, every setting checked (below) |
| `scripts/deploy.sh` | Run end to end against the replica; three bugs found and fixed (below) |
| `test/run-remote.sh` | The smoke tests against a server; 9/9 on the replica |
| `scripts/gen-secrets.sh` | Tested (the static checks use it) |
| CI workflow | Written; **never run** (the repo isn't on GitHub yet) |

**Smoke tests** (`npm test`, ~10s once images are built). All pass:

1. `/health` over HTTPS through Caddy.
2. HTTP gets a 308 redirect to HTTPS.
3. A guest sign-up works, so the database is reachable and migrations ran.
4. A Socket.IO client connects through Caddy, WebSocket only, authenticated,
   and its `ping` is echoed.
5. Only Caddy publishes a port. Postgres, the API and backups are
   unreachable from outside.
6. Data survives an API restart (a refresh token stored before still works).
7. Backup round trip: a guest made after the backup is gone after the
   restore, and one made before still works.
8. Backup retention keeps only the newest `BACKUP_KEEP` dumps.
9. The API stops cleanly on SIGTERM, well inside its 30s grace period.

**Static checks** (`npm run check`): compose config, shellcheck, and the
cloud-init schema.

**One lesson from writing the tests:** the first version of test 5 could
never fail. Compose prints ports without field names, so the pattern never
matched. It now parses Compose's JSON and first checks that it can see
Caddy's ports, so an empty list for the others means none. It's worth
asking the same of any test that checks for an absence.

**Measured footprint at idle, after a few sign-ups:**

| Service | Memory |
|---|---|
| API | 116 MB |
| Postgres | 38 MB |
| Caddy | 17 MB |
| Backup | <1 MB |

Images are built on your machine, not on the server, so the box needs no
headroom for builds. How far 512 MiB goes is measured below.

## Test on a $4-droplet replica

*2026-11-14, on a TrueNAS VM matching DigitalOcean's cheapest droplet
($4/month, $0.00595/hour): 1 vCPU, 512 MiB, a 10 GiB disk, Ubuntu 24.04's
cloud image booted with our cloud-init on a seed disk, as a droplet boots.*

**Provisioning (cloud-init):** finished in 112 s with no errors. Checked
over SSH and from outside:

- SSH as `deploy` with the key only; root login and passwords off.
- ufw denies everything incoming but 22, 80 and 443. From outside, 3000
  (API), 5432 (Postgres) and 6379 (Redis) are closed.
- fail2ban watching SSH; unattended security updates on; Docker and Compose
  installed; the 2 GB swap file on and in `/etc/fstab`.

**Docker and the firewall (closed 2026-11-14).** Docker writes its own
firewall rules for a published port, and they come before ufw's, so a port
a service publishes is open to the internet whatever ufw says. Only Caddy
published any, so nothing was open, but a later change could have opened
one by mistake. Two guards now:

- **`daemon.json` sets `"ip": "127.0.0.1"`**, so a port published without
  an address listens on the server only. Caddy's ports in `compose.yaml`
  name every IPv4 and IPv6 address. Tested on the replica: a container
  published on `5999` by mistake listened on `127.0.0.1` only, and was
  closed from the Mac over IPv4 and IPv6. Caddy still answered over both,
  and the smoke tests passed 9/9.
- **`test/static-checks.sh` refuses `ports` on any service but Caddy**,
  before anything reaches a server. Tested by adding `5432:5432` to
  Postgres: it failed, naming the port.

**Deploying:** `deploy.sh` and the smoke tests ran on the box. A deploy takes
about 2 minutes, mostly copying the image over SSH. Running it for real found
three bugs, all fixed:

1. **macOS's rsync put the files in the wrong place.** macOS now ships
   openrsync, which ignores the `/./` marker in a `--relative` path, so the
   files landed under `/opt/cchess/Users/<you>/...`. The script now runs
   rsync from inside the repo with plain relative paths.
2. **A changed Caddyfile was never applied.** Compose mounted the single
   file, and Docker pins a single-file mount to the file's inode; rsync
   replaces a file with a new one. The container kept the old file, and
   nothing reloaded Caddy anyway. Compose now mounts the `caddy/` folder,
   and each deploy reloads Caddy.
3. **HTTPS on an IP address failed the handshake.** A client sends no
   server name (SNI) to an IP, and Caddy 2.10 picks the certificate by that
   name. `default_sni` alone isn't enough, because Caddy only builds that
   policy for a site with its own `tls` line. The Caddyfile now names it:
   `tls {$CADDY_TLS}`, an email for Let's Encrypt or `internal` for testing.

And one that would have bitten soon after launch: **the disk would fill
after about four deploys.** A release leaves 1.5 GB free of the droplet's
8.7 GB, and each deploy added another ~370 MB image that nothing removed.
`deploy.sh` now keeps the image just deployed plus the 3 newest before it,
and clears unused layers and build cache. Testing that pruning found a
fourth bug: with tied creation times it removed the tag just deployed,
which a rollback could cause. That tag is now exempt.

**Memory at idle:** the kernel leaves 451 MB usable. Ubuntu and Docker take
~254 MB of that, leaving ~197 MB for a stack that needs ~170 MB, so the box
starts swapping even at idle (~230 MB in swap). Two services a VPS doesn't
need, `multipathd` (27 MB) and `snapd` (16 MB), are about a quarter of the
headroom; turning them off in cloud-init is an easy win, not yet made.

**Load test:** cchess-be's `scripts/load-test/load-test-remote.mjs` from a
Mac on the same LAN, over HTTPS through Caddy. Each game is a guest sign-up,
a WebSocket, a matchmaking seek and 40 scripted moves. Every move is made
the moment the opponent's arrives, so this is a burst far harsher than real
play.

| Simultaneous games (players) | Move latency p50 / p95 / p99 | Moves/s | Swap used (max) | Result |
|---|---|---|---|---|
| 10 (20) | 26 / 81 / 88 ms | 250 | 284 MB | ✓ |
| 25 (50) | 60 / 137 / 157 ms | 308 | 285 MB | ✓ |
| 50 (100) | 159 / 223 / 259 ms | 311 | 328 MB | ✓ |
| 100 (200) | 298 / 471 / 627 ms | 302 | 345 MB | ✓ |
| 200 (400) | 617 / 1,456 / 1,868 ms | 271 | 446 MB | ✓, slowing |
| 400 (800) | 5,487 / 9,149 / 10,011 ms | **68** | 611 MB | Finished, but **thrashing** |

No disconnects, no crashes, nothing killed for lack of memory, at any
size.

**Two limits show up:**

- **CPU, up to 200 games.** The one vCPU is at 95-100%, throughput levels
  off at ~300 moves a second, and latency grows with the queue.
- **Memory, at 400 games.** Throughput falls to 68 moves a second:
  swap-in reached 137 MB/s and the CPU spent up to 37% of its time waiting
  on disk.

**What that means for real play:** a blitz player moves every few seconds,
not instantly. 400 players at one move each per 5 s is ~80 moves a second,
well under the ~300 the box sustained. So a $4 droplet should serve a few
hundred people playing at once. Past that, memory runs out first; a 1 GB
droplet ($6) is the next step, and re-running this test at that size would
confirm the gain.

**How this replica differs from a real droplet:**

- **CPU:** the TrueNAS host's CPU is likely faster than DigitalOcean's
  shared vCPU, so the CPU limit above is probably optimistic. The memory
  limit carries over as measured.
- **Network:** a LAN has no latency; real players' moves also cross the
  internet.

**Found on the way: cchess-be's load-test harness was out of date.** It
seeks with `{ minutes, incrementSeconds }`, but the server now expects
`initialSeconds`. Every seek failed validation, and the harness didn't
listen for the `matchmaking:error` that said so; every run timed out with
"0 notified". It also allows only `games × 150 ms` to play, too little once
the box is the bottleneck. Both were patched in a scratch copy for this
test; the fix belongs in cchess-be.

## What's missing

Most important first.

1. **Let's Encrypt hasn't run.** cloud-init and `deploy.sh` now have, on
   the droplet replica, but getting a certificate needs a public domain and
   open ports 80/443. Point Caddy at Let's Encrypt's staging CA
   (`acme_ca https://acme-staging-v02.api.letsencrypt.org/directory`) for
   the first try, so a mistake doesn't hit the rate limits.
2. **Off-site backups aren't set up.** Dumps stay on the box until
   `RCLONE_REMOTE` is set. If the disk dies, they go with it. Set up an R2 or
   B2 bucket, private, with a lifecycle rule. Ideally wrap it in an
   [rclone `crypt`](https://rclone.org/crypt/) remote: the dumps contain
   password hashes and messages.
3. **No monitoring or alerts.** Nothing tells you if the API is down, a
   backup failed, or the disk is filling up. Free options:
   - an uptime check on `/health` (UptimeRobot, Better Stack);
   - a [healthchecks.io](https://healthchecks.io) ping at the end of
     `backup.sh`, which alerts when a night's ping doesn't arrive;
   - a disk-space alert.
4. **The API docs are public.** `main.ts` sets up Swagger at `/docs`
   unconditionally, so production would publish the whole API. That's
   harmless for a personal project, but worth turning off or
   password-protecting in production. Caddy can do it with `basic_auth` on
   `/docs*`, or cchess-be can skip it when `NODE_ENV=production`.
   `CORS_ORIGIN` also defaults to `*`. The native app doesn't need CORS, so
   that's fine until there's a web client.
5. **Single point of failure, by design.** A deploy, a crash or a host
   reboot drops every connection for a few seconds. Live games pause, and
   clients reconnect and rejoin. Kernel security updates install
   unattended, but they need a reboot to take effect, which isn't scheduled.
   Reboot monthly, or set
   `Unattended-Upgrade::Automatic-Reboot "true"` with a quiet hour.
6. **No image registry or continuous deployment.** `deploy.sh` builds on
   your machine and ships the image over ssh. That's simple and needs no
   accounts, but deploys depend on your laptop. The next step is a GitHub
   Actions job in cchess-be that pushes to GHCR on merges to `main`, with
   the server pulling from there.
7. **Migrations still also run on API boot** (`migrationsRun: true`).
   `migrate` now runs them first, so turning that off in cchess-be needs no
   change here. A rollback across a migration needs `migration:revert`
   first.
8. **512 MiB has little headroom.** It works (see the load test), but the
   box swaps at idle, and the backup image is built on the server, taking
   disk and build cache. Shipping the backup image like the API's, and
   turning off `multipathd` and `snapd` in cloud-init, would each help.
9. **No staging environment.** Every change lands straight in production.
   A second $5-6 box, or a second Compose project on the same box under
   another subdomain, would hold the test runs below.
10. **No resource limits.** A runaway API could starve Postgres of memory.
   Set `mem_limit` on `api` once real usage has been seen.
11. **Postgres major upgrades are manual.** The data volume is
    version-specific, so moving 18 → 19 means a dump and restore. The
    backup scripts already do most of that.
12. **Logs stay on the box,** rotated at 50 MB per service. That's fine at
    this size, but there's no search or retention beyond that.
13. **The CI workflow hasn't run.** It also needs a `CCHESS_BE_TOKEN`
    secret if cchess-be is private.
14. **Region and latency.** Hetzner's cheapest plans (CAX/CX) are only in
    the EU. For US players that adds ~80-100 ms per move. A US provider costs
    ~$12. See the costs below.

## How to test better

1. **A real, throwaway VPS per release.** The CI job:
   - creates a server through the provider's API (`hcloud`, `doctl`) with
     `cloud-init.yaml`;
   - points a test subdomain at it;
   - runs `deploy.sh`;
   - runs the smoke tests against it, with Let's Encrypt staging;
   - destroys the server.

   Hourly billing makes each run cost cents. This is the only test of
   points 1 and 5 above.
2. **Run the remote smoke tests after every deploy.** Done as
   `test/run-remote.sh`. Without `ALLOW_DESTRUCTIVE=1` it runs only the five
   read-only checks, so it's safe after a production deploy too.
3. **Scheduled restore drills.** Monthly, restore the latest *off-site*
   dump into a scratch Postgres container and check row counts. A backup
   you haven't restored is only a hope.
4. **Load testing at the target size.** Done for the $4 droplet (above).
   Repeat it at 1 GB before upgrading, and on a real droplet once, for its
   shared CPU and internet latency. Fix cchess-be's harness first.
5. **The app's Maestro e2e suite against staging.** It currently runs
   against a local server. Run against staging, it also covers TLS, real
   latency and reconnects across a deploy.
6. **Boot cloud-init on a fresh VM before changing it.** Done on the
   TrueNAS replica, whose zvol snapshots make it repeatable: rolling back to
   `pristine` gives a brand-new box that runs cloud-init again; `provisioned`
   gives one ready to deploy to.
7. **Test upgrades.** Restore a copy of the production dump, then run the
   new image's migrations against it before deploying. That catches a
   migration that only fails on real data.

## Monthly cost

All plans have 2 vCPU or more and at least 2 GB of RAM, per the sizing
above.

| Provider and plan | Region | Specs | Server | Backups (provider snapshots, optional) | Total |
|---|---|---|---|---|---|
| **DigitalOcean Basic, smallest** (tested, above) | US/EU | 1 vCPU, 512 MiB, 10 GiB, 500 GiB transfer | $4 | +$0.80 | **$4-4.80** |
| **Hetzner CAX11** (Arm) | EU | 2 vCPU, 4 GB, 40 GB | €5.99 + €0.50 IPv4 | +€1.20 | **€6.50-7.70 (~$7.50-9)** |
| Hetzner CX23 (x86) | EU | 2 vCPU, 4 GB, 40 GB | €5.49 + €0.50 IPv4 | +€1.10 | €6-7 (~$7-8) |
| DigitalOcean Basic | US/EU | 1 vCPU, 2 GB, 50 GB | $12 | +$2.40 | $12-14.40 |
| AWS Lightsail | US/EU | 2 vCPU, 2 GB, 60 GB, IPv4 | $12 | snapshots ~$0.05/GB | ~$12-13 |
| Vultr Cloud Compute | US/EU | 1 vCPU, 2 GB | ~$10 (unverified) | +20% | ~$10-12 |

Other costs:

| Item | Monthly |
|---|---|
| Off-site backup storage (R2 or B2; dumps are megabytes) | $0, inside both free tiers of 10 GB |
| Domain (.com, ~$10-15/year) | ~$1 |
| Monitoring (UptimeRobot, healthchecks.io free tiers) | $0 |
| TLS (Let's Encrypt) | $0 |
| Bandwidth (every plan includes 1-20 TB; a chess server uses a tiny fraction) | $0 |

**Total: ~$5-6/month on DigitalOcean's smallest droplet (enough for a few
hundred people playing at once, per the load test), ~$8-10/month on Hetzner
in the EU, ~$13-16/month for 2 GB on a US provider.**

For comparison, the AWS setup first considered (one Fargate task, an ALB, a
db.t4g.micro RDS, public IPv4s, Secrets Manager) comes to roughly
**$60-70/month** in us-east-1. Most of that is the load balancer, the
managed database and IPv4 charges, none of which this app can make use of.

**Caveats on prices:**

- **Hetzner** raised cloud prices twice in 2026 (April and 15 June). The
  figures above are after both, from third-party trackers rather than
  Hetzner's own page.
- **CX/CAX availability:** both lines have been listed as "currently not
  available" at times since late June. Check the Hetzner Console before
  counting on them.
- **Hetzner US:** its US locations only offer the CPX line, now ~$20/month
  for the entry plan, so they're no cheaper than DigitalOcean.
- **DigitalOcean:** one source reports a 20% cut to Basic plans in January
  2026, which would make 2 GB ~$9.60.
- **Vultr:** its 2 GB price wasn't confirmed.

Check each provider's own pricing page before buying.

## Sources

- Hetzner after the June 2026 increase: [devshot.co](https://devshot.co/blog/hetzner-cloud-pricing), [cloudtally.eu](https://cloudtally.eu/hetzner-cloud-prices), [northflank.com](https://northflank.com/blog/hetzner-cloud-server-price-increases), [wz-it.com](https://wz-it.com/en/blog/hetzner-price-increase-june-2026-cpx-ccx-alternatives/), [betterstack.com](https://betterstack.com/community/guides/web-servers/hetzner-cloud-review/)
- Hetzner April 2026 increase: [agentdeals.dev](https://agentdeals.dev/hetzner-pricing-2026), [bitdoze.com](https://www.bitdoze.com/hetzner-cloud-review/)
- DigitalOcean: [cloudpricecheck](https://cloudpricecheck-com.pages.dev/digitalocean/droplets-pricing), [activepieces.com](https://www.activepieces.com/blog/digitalocean-pricing-plans-and-real-costs-in-2026.md), [kuberns.com](https://kuberns.com/blogs/digitalocean-pricing/)
- Vultr: [vultr-guide](https://vultr-guide.pages.dev/blog/article-20260615.html), [costbench.com](https://www.costbench.com/software/cloud-infrastructure/vultr/)
- Lightsail: [AWS Lightsail bundles](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-bundles.html), [cloudburn.io](https://cloudburn.io/blog/amazon-lightsail-pricing)
- R2 and B2: [mecanik.dev](https://mecanik.dev/en/posts/cloudflare-r2-pricing-explained-real-costs-vs-s3-and-backblaze/), [agentdeals.dev](https://agentdeals.dev/backblaze-b2-vs-cloudflare-r2), [leanopstech](https://leanopstech-web.pages.dev/blog/backblaze-b2-pricing-2026/)
