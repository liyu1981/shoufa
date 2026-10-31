# Self-hosted Redis + storage adapter

Shoufa supports three storage backends behind one adapter interface. The
selection happens at runtime in `src/lib/storage/index.ts`:

| Priority | Backend | Required env vars | Notes |
| --- | --- | --- | --- |
| 1 | Self-hosted Zig server | `SHOUFA_REDIS_REST_URL`, `SHOUFA_REDIS_REST_TOKEN` | Wins when both are set |
| 2 | Upstash / cloud | `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN` | Fallback for production |
| 3 | In-process memory | none | Development only; not shared across instances |

Short aliases `SHOUFA_REDIS_URL` / `SHOUFA_REDIS_TOKEN` are also accepted.

## Why an adapter

`src/lib/store.ts` only depends on the `RedisAdapter` interface
(`src/lib/storage/types.ts`). Each implementation translates the same calls to
its own wire protocol:

- `memory.ts` wraps the existing `RedisMock` used for local development.
- `upstash.ts` wraps `@upstash/redis`.
- `self-hosted.ts` sends Upstash-compatible JSON command arrays over `fetch` to
  the Zig server.

This removes the old `instanceof RedisMock` branches from the storage layer and
makes backend choice a deployment concern rather than application logic.

## Local setup

```bash
# Terminal 1: build and start the Zig server
pnpm redis:selfhost

# Terminal 2: create .env.local
cat >> .env.local <<'ENV'
SHOUFA_REDIS_REST_URL=http://127.0.0.1:8079
SHOUFA_REDIS_REST_TOKEN=<key from ~/.config/shoufad/config>
ENV

pnpm dev
```

## Production setup

1. Build the server:
   ```bash
   pnpm redis:selfhost:build
   ```
2. Preview the systemd install:
   ```bash
   server/zig-out/bin/shoufad service-install --dry-run
   ```
3. Install it:
   ```bash
   sudo server/zig-out/bin/shoufad service-install
   ```
   The command copies the binary to `/usr/local/bin/shoufad`, creates the
   `shoufad` service user, writes `/etc/shoufad/config` with a generated API
   key, installs `/etc/systemd/system/shoufad.service`, enables it, and starts
   it.
4. Put nginx/Caddy in front for TLS if the web app is off-host, then set
   `SHOUFA_REDIS_REST_URL` and `SHOUFA_REDIS_REST_TOKEN` in the web app's
   environment. The token is printed by `service-install` and stored at
   `/etc/shoufad/config`.
5. Leave the Upstash variables set (or unset) as your fallback policy dictates.
   Self-hosted config always takes precedence when present.

To update, rebuild and re-run `sudo shoufad service-install`. The existing
config and API key are kept. Pass `--force` to rotate the key.

Useful service commands:

```bash
systemctl status shoufad
journalctl -u shoufad -f
sudo systemctl restart shoufad
```
