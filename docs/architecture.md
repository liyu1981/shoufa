# Architecture

Shoufa is a single self-hosted binary. `shoufad` serves:

- the Vite 8 + TanStack Router frontend (compiled into the binary)
- the same-origin JSON API
- `/wait` change notifications
- `/health`

There is no Vercel, Next.js server, Upstash, or Layerbase dependency.

## Request flow

```text
Browser
  ├─ GET /                 -> embedded index.html
  ├─ GET /assets/*         -> embedded Vite JS/CSS
  ├─ GET /s/<slug>         -> embedded index.html (SPA fallback)
  ├─ GET /api/...          -> Zig JSON API -> in-memory store
  ├─ POST/DELETE /api/...  -> Zig JSON API -> in-memory store
  └─ GET /wait?slug=...    -> long-poll room revision
```

When a room changes, the server increments its revision. The browser's
`/wait` request returns and the client refreshes `/api/<slug>/assets` and
`/api/<slug>/status` once. Idle rooms generate no API requests.

## Storage

- In-memory strings and hashes, capped at 5 GiB by default.
- Per-key TTL, reclaimed lazily and by a background sweeper.
- Single node, non-persistent by design.

## Frontend

- Vite 8 + React 19 + TanStack Router, built as a static SPA.
- The build writes files to `server/src/web`.
- `scripts/generate-web-assets.mjs` embeds those files into
  `server/src/web_assets.zig`; `server/build.zig` runs this automatically.
- No runtime Node.js process is needed.

## Security

- Everything is same-origin; no API token is required.
- Unsafe API requests are checked against `Origin` / `Sec-Fetch-Site`.
- CSP and related hardening headers are added by the Zig server.
- Raw Redis protocol commands are not exposed.
