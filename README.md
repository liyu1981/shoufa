# Shoufa

**Paste. Share. Disappear.**

An ephemeral clipboard with a time limit. Paste text, images, or files, share a
memorable link, and watch it auto-expire.

## Stack

- **Frontend:** Vite 8, React 19, TanStack Router, Tailwind CSS v4
- **Backend:** Zig (`shoufad`) serving the API, change notifications, and the
  embedded frontend from one binary
- **Storage:** in-memory strings/hashes with TTL cleanup, capped at 5 GiB
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
max_memory_bytes = 5368709120
max_request_bytes = 16777216
sweep_interval_ms = 1000
```

The server should stay on `127.0.0.1` behind a TLS reverse proxy (Caddy, nginx,
or Cloudflare Tunnel). There is no API token: the browser and API share an
origin, and unsafe requests are checked for same-origin headers.

Optional build-time canonical URL:

```bash
VITE_SITE_URL=https://shoufa.example.com pnpm build
```

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

## Notes

- Single node, non-persistent. Data is lost on restart.
- Defaults: 5 GiB store, 5 MiB image limit, 1 hour max TTL.
- See [`docs/architecture.md`](./docs/architecture.md) and
  [`server/README.md`](./server/README.md).

## License

MIT
