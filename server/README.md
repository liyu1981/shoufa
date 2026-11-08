# shoufad

Self-hosted Shoufa server written in Zig. It serves the embedded Vite frontend
and the same-origin JSON API from one process.

## Version

`VERSION` in the repository root is the source of truth. `shoufad --version`
and `/health` expose it.

```bash
./zig-out/bin/shoufad --version
curl http://127.0.0.1:8079/health
```

## Build

Requirements:

- Zig 0.17+
- Node.js 22+ (for the Vite build and asset embedding)

```bash
# From the repo root
pnpm build
```

This runs `vite build`, writes the frontend to `server/src/web`, generates
`server/src/web_assets.zig`, and compiles the binary.

SQLite is vendored (`vendor/sqlite/sqlite3.c`) and compiled into the binary, so
no system SQLite package is required and musl cross-builds stay self-contained.

Unit tests cover the object format, the metadata index, and the LRU/disk
fallback behaviour of the store:

```bash
cd server
zig build test
```

Run manually:

```bash
./server/zig-out/bin/shoufad
# or, from server/
zig build -Doptimize=ReleaseSafe
./zig-out/bin/shoufad
```

The config is created at `~/.config/shoufad/config` on first run. Use
`--config PATH` or `SHOUFA_CONFIG` to override it. `--bind` and `--port` can
override the config for a single run:

```bash
./zig-out/bin/shoufad --bind 0.0.0.0 --port 8079
```

Use `--data PATH` to point a run at a different data directory.

## Config

See [`config.example`](./config.example).

| Key | Default | Description |
| --- | --- | --- |
| `bind` | `127.0.0.1` | Listen interface |
| `port` | `8079` | Listen port |
| `data_dir` | `~/.shoufa/data` | SQLite metadata index + sharded object store |
| `max_memory_bytes` | `512 MiB` | In-memory LRU cache budget; values above 5 GiB are rejected |
| `max_request_bytes` | `16 MiB` | Max JSON request body |
| `sweep_interval_ms` | `1000` | Expired-key sweep interval |

There are no API keys. The frontend and API are same-origin.

`--data PATH` (or `SHOUFA_DATA` / `XDG_DATA_HOME`) overrides `data_dir` for a
single run.

### Create or upgrade a file

```bash
./zig-out/bin/shoufad config             # create ./config with default values
./zig-out/bin/shoufad config --upgrade   # migrate ./config, keeping its values
```

Both take `--config PATH` (default `./config`). An upgrade copies the original
to `<path>.bak`, normalises legacy key names and size spellings, then reports
the keys it kept, the ones it filled in with defaults, the retired keys it
dropped (`api_key`, `allow_anonymous`, …), and any key it did not recognise.
It refuses to overwrite a file that does not look like a shoufa config and is
idempotent on a file that is already current.

## Storage

Everything is written through to disk; memory only holds a bounded cache.

```text
<data_dir>/
├── meta.sqlite3        # key, expiry, field count, object path (WAL mode)
├── meta.sqlite3-wal
├── meta.sqlite3-shm
└── objects/ab/cd/<sha256>   # git-style two-level sharding
```

- **Write:** serialize the hash → atomically write the object file → upsert the
  SQLite row → keep/insert the entry in the LRU cache.
- **Read:** check the cache first; on a miss read the SQLite row, load the
  object, verify its CRC, and re-admit it to the cache.
- **Eviction:** when `max_memory_bytes` is exceeded the least recently used
  entries leave memory. Their disk copy stays, so the next read reloads them.
- **Expiry:** the sweeper removes expired keys from memory and from disk
  (metadata row and object file).

Because values live on disk, `max_memory_bytes` is a cache budget (hard cap
5 GiB) rather than a total store limit. Existing configs that set 5 GiB keep
working unchanged.

## systemd

System service:

```bash
sudo ./server/zig-out/bin/shoufad service-install
```

User service:

```bash
./server/zig-out/bin/shoufad service-install
```

The binary contains the frontend, so the installer only copies the executable
and writes the config/unit.

Preview either mode:

```bash
./server/zig-out/bin/shoufad service-install --dry-run
```

## API

- `POST /api/slugs` — create a slug
- `GET /api/:slug/exists`
- `GET /api/:slug/status`
- `GET /api/:slug/assets`
- `POST /api/:slug/assets` — JSON text or file/image data URL
- `DELETE /api/:slug/assets/:id`
- `DELETE /api/:slug`
- `GET /wait?slug=...&rev=...` — long-poll change notifications
- `GET /health`

Text upload example:

```bash
curl -X POST http://127.0.0.1:8079/api/demo/assets \
  -H 'content-type: application/json' \
  -d '{"content":"hello","ttl":300}'
```

File/image uploads use:

```json
{
  "type": "image",
  "data": "data:image/png;base64,...",
  "mimeType": "image/png",
  "fileName": "photo.png",
  "size": 12345,
  "ttl": 300
}
```

## Change notifications

The browser long-polls:

```text
GET /wait?slug=<slug>            # initialize, returns current revision
GET /wait?slug=<slug>&rev=<n>    # wait up to 25s for a change
```

Only a revision counter is exposed. On a change, the client refreshes the
normal API once. Idle rooms generate no API requests.

## Security

The server sets CSP and related hardening headers. Unsafe API requests are
checked for same-origin `Origin`/`Sec-Fetch-Site`. Raw Redis protocol commands
are not exposed.

Keep `bind = 127.0.0.1` and terminate TLS with Caddy, nginx, or Cloudflare
Tunnel. Do not expose the port directly.
