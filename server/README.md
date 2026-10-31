# shoufad

Self-hosted Shoufa server written in Zig. It serves the embedded Vite frontend
and the same-origin JSON API from one process.

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

## Config

See [`config.example`](./config.example).

| Key | Default | Description |
| --- | --- | --- |
| `bind` | `127.0.0.1` | Listen interface |
| `port` | `8079` | Listen port |
| `max_memory_bytes` | `5 GiB` | Store budget; values above 5 GiB are rejected |
| `max_request_bytes` | `16 MiB` | Max JSON request body |
| `sweep_interval_ms` | `1000` | Expired-key sweep interval |

There are no API keys. The frontend and API are same-origin.

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
