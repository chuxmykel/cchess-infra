// The stack as a client sees it, through Caddy - run by test/run-local.sh
// (the stack in Docker here) or test/run-remote.sh (a server). The tests in
// this file run in order, and later ones build on earlier ones' state (a
// guest made, a backup taken).
//
// On a server, the tests that restart or stop the api or restore a backup
// over the database run only with ALLOW_DESTRUCTIVE=1: never on one with
// real players.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { after, test } from 'node:test';

import { io } from 'socket.io-client';

const BASE_URL = process.env.BASE_URL ?? 'https://localhost:8443';
const HTTP_URL = process.env.HTTP_URL ?? 'http://localhost:8080';
// Set by run-remote.sh: the server's ssh host, and the stack's folder there.
const REMOTE_HOST = process.env.REMOTE_HOST;
const REMOTE_DIR = process.env.REMOTE_DIR ?? '/opt/cchess';
const DESTRUCTIVE = !REMOTE_HOST || process.env.ALLOW_DESTRUCTIVE === '1';
const destructive = { skip: !DESTRUCTIVE && 'a server, without ALLOW_DESTRUCTIVE=1' };
const LOCAL_COMPOSE_ARGS = [
  'compose',
  '--env-file',
  process.env.ENV_FILE ?? 'test/test.env',
  '-f',
  'compose.yaml',
  '-f',
  'compose.local.yaml',
];

const shellQuote = (arg) => `'${arg.replaceAll("'", "'\\''")}'`;

function compose(...args) {
  const options = { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] };
  if (!REMOTE_HOST) return execFileSync('docker', [...LOCAL_COMPOSE_ARGS, ...args], options);
  const command = `cd ${shellQuote(REMOTE_DIR)} && docker compose ${args.map(shellQuote).join(' ')}`;
  return execFileSync('ssh', [REMOTE_HOST, command], options);
}

// The last test stops the api; a server is left serving again.
after(() => {
  if (REMOTE_HOST && DESTRUCTIVE) compose('up', '-d', '--wait', 'api');
});

async function newGuest() {
  const res = await fetch(`${BASE_URL}/auth/guest`, { method: 'POST' });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.ok(body.accessToken && body.refreshToken);
  return body;
}

/** The refresh's status, and the rotated tokens when it worked. */
async function refresh(refreshToken) {
  const res = await fetch(`${BASE_URL}/auth/refresh`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ refreshToken }),
  });
  return { status: res.status, body: res.ok ? await res.json() : null };
}

async function waitForHealthy() {
  const deadline = Date.now() + 60_000;
  for (;;) {
    try {
      const res = await fetch(`${BASE_URL}/health`);
      if (res.ok) return;
    } catch {
      // Caddy answers 502 or the connection drops while the api restarts.
    }
    if (Date.now() > deadline) throw new Error('api not healthy after 60s');
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
}

test('serves /health over HTTPS through Caddy', async () => {
  const res = await fetch(`${BASE_URL}/health`);
  assert.equal(res.status, 200);
});

test('redirects plain HTTP to HTTPS', async () => {
  const res = await fetch(`${HTTP_URL}/health`, { redirect: 'manual' });
  assert.equal(res.status, 308);
  assert.ok(
    res.headers.get('location').startsWith(`https://${new URL(BASE_URL).hostname}/`),
    res.headers.get('location'),
  );
});

test('creates a guest: the api reaches Postgres and its migrations ran', async () => {
  await newGuest();
});

test('upgrades to a WebSocket through Caddy, authenticated', async () => {
  const { accessToken } = await newGuest();
  const socket = io(BASE_URL, {
    transports: ['websocket'],
    auth: { token: accessToken },
    reconnection: false,
  });
  try {
    await new Promise((resolve, reject) => {
      socket.once('connect', resolve);
      socket.once('connect_error', reject);
    });
    // The server drops a socket whose token it refuses right after
    // connecting; an answer to `ping` means it was accepted.
    const sent = Date.now();
    const echoed = await socket.timeout(5000).emitWithAck('ping', sent);
    assert.equal(echoed, sent);
  } finally {
    socket.disconnect();
  }
});

test('publishes no port but Caddy\'s', () => {
  // One JSON object per line, each container's ports with the host port
  // they're published on - 0 when they aren't.
  const published = Object.fromEntries(
    compose('ps', '--format', 'json')
      .trim()
      .split('\n')
      .map((line) => JSON.parse(line))
      .map((c) => [
        c.Service,
        (c.Publishers ?? []).map((p) => p.PublishedPort).filter(Boolean),
      ]),
  );
  // Caddy's are seen, so an empty list elsewhere means none, not unread.
  const httpsPort = Number(new URL(BASE_URL).port || 443);
  assert.ok(published.caddy.includes(httpsPort), JSON.stringify(published));
  for (const service of ['postgres', 'api', 'backup']) {
    assert.deepEqual(published[service], [], `${service} publishes a port`);
  }
});

/** scripts/maintenance.sh's request, made the same way: from inside the
 * api's container. */
function maintenanceRequest(method, body = '') {
  const script = readFileSync('scripts/maintenance-request.js', 'utf8');
  const out = compose('exec', '-T', '-e', `METHOD=${method}`, '-e', `BODY=${body}`, 'api', 'node', '-e', script);
  return out.trim() ? JSON.parse(out) : null;
}

test('keeps the maintenance controls off the internet', async () => {
  const res = await fetch(`${BASE_URL}/internal/maintenance`);
  assert.equal(res.status, 404);
  // ...and inside the container they answer.
  assert.equal(typeof maintenanceRequest('GET').liveGames, 'number');
});

// Destructive on a server: its players would be shown the banner.
test('announces maintenance, shown to the app, and ends it', destructive, async () => {
  const started = maintenanceRequest('PUT', '{"minutes":5}');
  assert.ok(started.startsAt);
  assert.ok(started.secondsToStart > 4 * 60, JSON.stringify(started));
  const shown = await (await fetch(`${BASE_URL}/maintenance`)).json();
  assert.equal(shown.startsAt, started.startsAt);

  maintenanceRequest('DELETE');
  const ended = await (await fetch(`${BASE_URL}/maintenance`)).json();
  assert.equal(ended.startsAt, null);
});

let survivor;

test('keeps its data through an api restart', destructive, async () => {
  const guest = await newGuest();
  compose('restart', 'api');
  await waitForHealthy();
  // A refresh token is a database row, unlike the access token's signature.
  const { status, body } = await refresh(guest.refreshToken);
  assert.equal(status, 200);
  survivor = body;
});

test('restores a backup: what came after it is gone, what came before stays', destructive, async () => {
  const out = compose('exec', '-T', 'backup', 'backup.sh');
  assert.match(out, /wrote cchess-.*\.dump/);
  const afterBackup = await newGuest();

  compose('stop', 'api');
  compose('exec', '-T', 'backup', 'restore.sh', 'latest');
  compose('start', 'api');
  await waitForHealthy();

  assert.equal((await refresh(afterBackup.refreshToken)).status, 401);
  assert.equal((await refresh(survivor.refreshToken)).status, 200);
});

test('keeps only the newest BACKUP_KEEP backups', destructive, () => {
  const keep = Number(
    compose('exec', '-T', 'backup', 'sh', '-c', 'echo $BACKUP_KEEP').trim(),
  );
  for (let i = 0; i <= keep; i++) {
    compose('exec', '-T', 'backup', 'backup.sh');
    // The names are to the second.
    execFileSync('sleep', ['1']);
  }
  const files = compose('exec', '-T', 'backup', 'sh', '-c', 'ls /backups/*.dump')
    .trim()
    .split('\n');
  assert.equal(files.length, keep);
});

test('stops gracefully, well inside its 30s grace period', destructive, () => {
  const started = Date.now();
  compose('stop', 'api');
  const seconds = (Date.now() - started) / 1000;
  const state = compose('ps', '-a', '--format', '{{.ExitCode}}', 'api').trim();
  // tini passes on SIGTERM, and Nest re-raises it once its shutdown hooks
  // are done (143); a SIGKILL after the grace period would be 137.
  assert.ok(['0', '143'].includes(state), `exit code ${state}`);
  assert.ok(seconds < 15, `took ${seconds}s`);
});
