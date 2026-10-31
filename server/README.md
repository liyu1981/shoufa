# shoufad

A small, dependency-free **Redis-compatible REST server** written in Zig. It is
the self-hosted storage backend for Shoufa and speaks the same wire format as
Upstash Redis, so the Next.js app can switch between the two without changing
any application logic.

## What it does

- Stores strings and hashes entirely in memory.
- Supports per-key TTL (`SET ... EX/PX`, `EXPIRE`, `PEXPIRE`, `EXPIREAT`).
- Reclaims expired keys **lazily on access** and **proactively with a sweeper**,
  freeing their allocations back to the allocator.
- Enforces a memory budget (default and hard cap: **5 GiB**). Writes that would
  exceed the budget return an OOM error instead of growing without bound.
- Authenticates requests with Bearer API keys read from a config file.

It is intentionally **single-node and non-persistent**: data is lost when the
process exits. That matches Shoufa's ephemeral model.

## Build and run

Requires Zig **0.17.0+**.

```bash
cd server
zig build -Doptimize=ReleaseSafe
./zig-out/bin/shoufad
```

Or from the repo root:

```bash
pnpm redis:selfhost
```

### First run

If the config file does not exist, the server creates it with a random API key:

```
~/.config/shoufad/config
```

The file is written with `0600` permissions and the generated key is printed to
the log. Copy that key into `SHOUFA_REDIS_REST_TOKEN` for the web app.

Use a different config file with `--config` or `SHOUFA_REDIS_CONFIG`:

```bash
./zig-out/bin/shoufad --config /etc/shoufad/config
```

## Install as a systemd service (Linux)

The binary can install itself:

```bash
sudo ./zig-out/bin/shoufad service-install
```

This command:

1. Copies the running binary to `/usr/local/bin/shoufad`.
2. Creates the `shoufad` system user (skip with `--user root` or an existing user).
3. Creates `/etc/shoufad/config` with a random API key if it does not exist.
4. Writes `/etc/systemd/system/shoufad.service`.
5. Runs `systemctl daemon-reload`, enables the unit, and starts/restarts it.

Preview everything first without touching the system:

```bash
./zig-out/bin/shoufad service-install --dry-run
```

Useful options:

```text
--binary PATH    Install path (default /usr/local/bin/shoufad)
--config PATH    Config path (default /etc/shoufad/config)
--service NAME   systemd unit name (default shoufad)
--user NAME      service user (default shoufad)
--no-start       Enable at boot but do not start/restart now
--force          Overwrite the config and rotate the API key
--dry-run, -n    Print the plan and generated unit file only
```

Re-running `sudo shoufad service-install` updates the binary and unit while
keeping the existing config/API key. Run `systemctl status shoufad` to check it.

## Configuration

See [`config.example`](./config.example). The format is simple `key = value`
lines; `#` starts a comment.

| Key | Default | Description |
| --- | --- | --- |
| `bind` | `127.0.0.1` | Interface to listen on |
| `port` | `8079` | TCP port |
| `max_memory_bytes` / `max_memory` | `5 GiB` | Memory budget; values above 5 GiB are rejected |
| `max_request_bytes` | `128 MiB` | Maximum HTTP request body |
| `sweep_interval_ms` | `1000` | Background expired-key sweep interval |
| `api_key` | generated | Bearer token; repeat the line for multiple keys |
| `allow_anonymous` | `false` | Disable auth (**not recommended**) |

`max_memory` accepts suffixes such as `512MB`, `2GiB`, or `5GB`.

## HTTP API

All authenticated endpoints expect:

```
Authorization: Bearer <api_key>
```

### Single command

```bash
curl -X POST http://127.0.0.1:8079/ \
  -H "Authorization: Bearer $TOKEN" \
  -d '["HSET","slug:demo","a","1"]'
# {"result":1}
```

### Pipeline

```bash
curl -X POST http://127.0.0.1:8079/pipeline \
  -H "Authorization: Bearer $TOKEN" \
  -d '[["PING"],["GET","slug:demo"]]'
# [{"result":"PONG"},{"result":null}]
```

### Path commands (optional)

```bash
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8079/get/slug:demo
curl http://127.0.0.1:8079/health
```

### Supported commands

- Keys: `EXISTS`, `DEL`, `UNLINK`, `EXPIRE`, `PEXPIRE`, `EXPIREAT`,
  `PEXPIREAT`, `TTL`, `PTTL`, `PERSIST`, `TYPE`, `DBSIZE`, `FLUSHDB`,
  `FLUSHALL`, `INFO`
- Strings: `GET`, `SET` (`EX`, `PX`, `NX`, `XX`, `KEEPTTL`), `INCR`, `DECR`,
  `INCRBY`, `DECRBY`, `ECHO`, `PING`
- Hashes: `HSET`, `HMSET`, `HGET`, `HGETALL`, `HDEL`, `HEXISTS`, `HLEN`,
  `HKEYS`, `HVALS`

Errors use the Upstash shape: `{"error":"..."}`.

`@upstash/redis` compatibility is built in:

- `HGETALL` is returned as a flat `[field, value, ...]` array, which the
  Upstash client converts to an object.
- When a request includes `Upstash-Encoding: base64`, every string in a
  successful result is base64-encoded. Clients that do not send the header get
  plain JSON strings.

## Memory and TTL behavior

Memory is accounted conservatively: key bytes, value bytes, field names, and a
small per-key/per-field overhead. This ensures the configured cap tracks actual
allocator usage closely.

1. A key with a TTL is checked on every access. If expired, it is removed and
   its string/hash allocations are freed immediately.
2. A background sweeper scans for expired keys every `sweep_interval_ms` and
   frees them even if they are never accessed again.
3. If a write would exceed `max_memory_bytes`, expired keys are swept first. If
   there is still no room, the write is rejected with `OOM command not allowed
   when used memory > 'maxmemory'.`

Because free-space reclamation is allocator-based, RSS may not drop instantly
for every small allocation, but the reclaimed memory is available for new keys
and large allocations are returned to the OS.

## Deployment notes

- Run **one instance**. There is no replication or shared state.
- Prefer `sudo shoufad service-install` over hand-writing a unit. The generated
  unit runs as a dedicated user and enables basic systemd hardening.
- Keep `bind = 127.0.0.1` and put a TLS-terminating reverse proxy (Caddy, nginx)
  in front if the app is on another machine.
- Use a strong generated API key and keep the config file at `0600`.
- Set `SHOUFA_REDIS_REST_URL` and `SHOUFA_REDIS_REST_TOKEN` in the web app.
  Only set the Upstash variables if you want the cloud fallback.
- The server has no disk persistence by design.
