# Shoufa

**Paste. Share. Disappear.**

An ephemeral clipboard with a time limit. Paste text, images, or files, share a
memorable link, and watch it auto-expire.

## Stack

- **Frontend:** Vite 8, React 19, TanStack Router, Tailwind CSS v4
- **Backend:** Zig (`shoufad`) serving the API, change notifications, and the
  embedded frontend from one binary
- **Storage:** SQLite metadata index + git-style sharded objects on disk, with
  a bounded in-memory LRU cache on top
- **No Node.js runtime in production**, no Vercel, no Upstash/Layerbase

The frontend build is embedded into the `shoufad` binary. One process serves
`/`, `/s/<slug>`, `/api/*`, `/wait`, and `/health`.

## Development

```bash
pnpm install
pnpm dev
```

`pnpm dev` runs the full local loop:

1. Build the Vite frontend into `server/src/web`
2. Embed it into the Zig binary and build `shoufad`
3. Start `shoufad`
4. Watch `src/`, `public/`, `scripts/`, `server/src/`, and build files
5. Rebuild and restart automatically when anything changes

Dev listens on `0.0.0.0:8079`, so phones and other devices on the LAN can
connect. Open the URL printed by `shoufad`.

To restrict it to localhost:

```bash
pnpm dev -- --bind 127.0.0.1
```

To use a different config:

```bash
pnpm dev -- --config /path/to/config
```

For a production-like run:

```bash
pnpm build     # vite build + embed + zig build -Doptimize=ReleaseSafe
pnpm start     # runs server/zig-out/bin/shoufad
```

The config file is created at `~/.config/shoufad/config` on first run. For a
systemd deployment:

```bash
sudo server/zig-out/bin/shoufad service-install
```

or as a user service:

```bash
server/zig-out/bin/shoufad service-install
```

The service installer copies the binary and creates the unit. The frontend is
already embedded, so there is nothing else to deploy.

## Configuration

See [`server/config.example`](./server/config.example).

```ini
bind = 127.0.0.1
port = 8079
data_dir = ~/.shoufa/data
max_memory_bytes = 536870912
max_request_bytes = 16777216
sweep_interval_ms = 1000
```

The server should stay on `127.0.0.1` behind a TLS reverse proxy (Caddy, nginx,
or Cloudflare Tunnel). There is no API token: the browser and API share an
origin, and unsafe requests are checked for same-origin headers.

### Creating or upgrading a config

```bash
shoufad config             # write ./config with default values
shoufad config --upgrade   # rewrite ./config in the current format, keeping
                           # its values; the original goes to ./config.bak
```

Both accept `--config PATH` (default `./config`). An upgrade normalises old key
spellings (`max_memory = 5GB` → `max_memory_bytes = 5000000000`), adds the keys
a current build expects, and reports what it could not carry over — including
the retired `api_key` / `allow_anonymous` keys from the Redis era. It refuses to
touch a file that does not look like a shoufa config, and re-running it on an
already-current file is a no-op.

Optional build-time canonical URL:

```bash
VITE_SITE_URL=https://shoufa.example.com pnpm build
```

## Storage

Every value is persisted to disk under `data_dir` (default `~/.shoufa/data`):

```text
~/.shoufa/data/
├── meta.sqlite3        # key, expiry, field count, object path
└── objects/ab/cd/…     # git-style sharded hash objects (SHA-256 path)
```

`max_memory_bytes` only bounds the **in-memory cache**. Writes go to disk
first and also land in the cache; reads check the cache and fall back to disk,
loading the value back into memory when there is room. When the budget is
exceeded the least recently used values are evicted from memory — nothing is
dropped from disk.

## API

- `POST /api/slugs` — create a room
- `GET /api/:slug/exists`
- `GET /api/:slug/status`
- `GET /api/:slug/assets`
- `POST /api/:slug/assets` — text or file/image as a data URL
- `DELETE /api/:slug/assets/:id`
- `DELETE /api/:slug`
- `GET /wait?slug=...&rev=...` — room revision long-poll
- `GET /health`

File and image uploads are sent as JSON data URLs, so the frontend and backend
share one simple JSON contract. No multipart parser is needed.

## Security

- Same-origin only; no API secret.
- Cross-origin unsafe requests are rejected via `Origin` and `Sec-Fetch-Site`.
- CSP, HSTS, `X-Content-Type-Options`, `Referrer-Policy`,
  `Permissions-Policy`, COOP/CORP, and frame denial are set by the Zig server.
- Raw Redis protocol commands are not exposed.

## Versioning and releases

The root [`VERSION`](./VERSION) file is the source of truth. It is injected into:

- `shoufad --version`
- `GET /health`
- the frontend footer (`powered by shoufad · vX.Y.Z`)
- the HTML `generator` metadata

Set a new version with:

```bash
pnpm release:version 0.3.0
git add VERSION package.json server/build.zig.zon
git commit -m "chore: release v0.3.0"
git tag v0.3.0
git push origin main --tags
```

GitHub Actions:

- `.github/workflows/ci.yml` runs lint, typecheck, build, and a server smoke test
  on pushes to `main` and pull requests.
- `.github/workflows/release.yml` runs on `v*` tags, verifies the tag matches
  `VERSION`, and publishes x86_64/aarch64 Linux tarballs with checksums.

## Notes

- Single node. Data is persisted under `~/.shoufa/data` and survives restarts.
- Defaults: 512 MiB memory cache (LRU), 5 MiB image limit, 1 hour max TTL.
- Room revision counters (`/wait`) are process-local; a restart makes clients
  refresh once.
- See [`docs/architecture.md`](./docs/architecture.md) and
  [`server/README.md`](./server/README.md).

## License

MIT
