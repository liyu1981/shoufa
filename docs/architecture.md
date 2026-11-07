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
  ├─ GET /api/...          -> Zig JSON API -> LRU cache / SQLite + objects
  ├─ POST/DELETE /api/...  -> Zig JSON API -> LRU cache / SQLite + objects
  └─ GET /wait?slug=...    -> long-poll room revision
```

When a room changes, the server increments its revision. The browser's
`/wait` request returns and the client refreshes `/api/<slug>/assets` and
`/api/<slug>/status` once. Idle rooms generate no API requests.

## Storage

Every value is persisted, and memory only holds a bounded hot set.

```text
~/.shoufa/data/
├── meta.sqlite3      # key, expires_at, field count, object path, updated_at
└── objects/ab/cd/…   # SHA-256 sharded hash objects (two levels, like git)
```

- **Metadata** (key, expiry, field count, object size, object path) lives in
  SQLite in WAL mode. An index on `expires_at` drives the expiry sweep.
- **Values** are serialized length-prefixed binary blobs with a CRC-32
  trailer, written atomically through a temporary file + rename.
- **Memory** is an LRU cache sized by `max_memory_bytes` (default 512 MiB,
  hard cap 5 GiB). Writes go to disk first and update the cache; reads check
  the cache and fall back to disk, re-admitting the value when there is room.
  Exceeding the budget evicts the least recently used entries from memory
  only.
- **Expiry** is enforced lazily on access and by a background sweeper that
  removes both the metadata row and the object file.
- **Revisions** for `/wait` stay process-local; after a restart clients
  observe one spurious change and refresh.

Storage is single-node. SQLite is vendored in `server/vendor/sqlite`.

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

## Versioning

The root `VERSION` file is injected into the Zig binary (`shoufad --version`,
`/health`), the frontend bundle, and the HTML generator metadata. Release tags
use the `vX.Y.Z` form; the release workflow refuses to publish if the tag does
not match `VERSION`.
