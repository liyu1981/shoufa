# Shoufa

**Paste. Share. Disappear.**

An ephemeral clipboard with a time limit. Paste text or images, share the link, and watch it auto-expire.

## Use Cases

- 📋 **Share code snippets** — Paste code and share the link; expires automatically
- 🔐 **Send passwords** — Share credentials securely; they disappear after viewing
- 📱 **Transfer between devices** — Paste on phone, copy on desktop (or vice versa)
- 🖼️ **Quick image sharing** — Upload screenshots or photos with a self-destructing link
- 🤝 **Team collaboration** — Share quick notes without cluttering chat
- 🎫 **One-time secrets** — API keys, tokens, or sensitive info that shouldn't persist

## Tech Stack

- **Next.js 16** (App Router)
- **TypeScript**
- **Tailwind CSS v4** + Apple glass design system
- **Jotai** for state management
- **Pluggable Redis storage** — self-hosted Zig server, Upstash, or in-memory
- **Zig 0.17+** self-hosted Redis-compatible REST server

## Storage backends

`src/lib/storage/` contains one adapter interface and three implementations. The
runtime picks the first configured backend:

1. **Self-hosted** — `SHOUFA_REDIS_REST_URL` + `SHOUFA_REDIS_REST_TOKEN`
2. **Upstash / cloud fallback** — `UPSTASH_REDIS_REST_URL` + `UPSTASH_REDIS_REST_TOKEN`
3. **In-process memory** — development fallback when neither is configured

Self-hosted always wins when both are present, so production can prefer your own
server while keeping the cloud variables as a fallback for other environments.
See [`docs/self-hosted-redis.md`](./docs/self-hosted-redis.md) and
[`server/README.md`](./server/README.md).

## Development

```bash
# Install dependencies
pnpm install

# Option A: self-hosted Zig server (recommended, no account needed)
pnpm redis:selfhost
# First run creates ~/.config/shoufad/config with a random API key.
# Copy that key into SHOUFA_REDIS_REST_TOKEN below.

# Option B: temporary Upstash Redis (no account needed)
pnpm redis

# Start dev server (HTTPS, port 3210)
pnpm dev

# Open https://localhost:3210
```

For self-hosted local development, add to `.env.local`:

```bash
SHOUFA_REDIS_REST_URL=http://127.0.0.1:8079
SHOUFA_REDIS_REST_TOKEN=sfr_your-generated-key
```

If no storage env vars are set, the app uses the in-memory mock. Data resets on
restart and is not shared between processes, so use a real backend for anything
beyond local development.

## Deployment

### Self-hosted Zig Redis (recommended for cost control)

1. Build the server:
   ```bash
   pnpm redis:selfhost:build
   ```
2. Install it as a systemd service:
   ```bash
   sudo server/zig-out/bin/shoufad service-install
   ```
   This copies the binary to `/usr/local/bin/shoufad`, creates a `shoufad`
   service user, writes `/etc/shoufad/config` with a generated API key, installs
   `/etc/systemd/system/shoufad.service`, and starts it. Use `--dry-run` first to
   preview the changes.
3. Re-run the same command after rebuilding to update the binary/service. The
   existing config and API key are kept unless you pass `--force`.
4. Set these on your app host / Vercel project:
   ```bash
   SHOUFA_REDIS_REST_URL=https://redis.your-domain.com
   SHOUFA_REDIS_REST_TOKEN=sfr_your-key
   ```
   Keep the server behind TLS if the app is off-host.

The server keeps everything in memory with a hard 5 GiB cap and proactively
reclaims memory for expired keys. It is single-node and non-persistent by design.

### Vercel + Upstash (cloud fallback)

1. **Create Upstash Redis:**
   - Go to [Upstash Console](https://console.upstash.com)
   - Create a new Redis database (free tier: 10,000 commands/day)
   - Copy the `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`

2. **Deploy:**
   ```bash
   pnpm add -g vercel
   vercel

   # Add environment variables
   vercel env add UPSTASH_REDIS_REST_URL
   vercel env add UPSTASH_REDIS_REST_TOKEN

   # Optional: self-hosted takes precedence if these are also set
   vercel env add SHOUFA_REDIS_REST_URL
   vercel env add SHOUFA_REDIS_REST_TOKEN

   # Deploy to production
   vercel --prod
   ```

Or connect via Vercel Dashboard:
1. Push to GitHub
2. Import project in Vercel
3. Add environment variables from Upstash and/or the self-hosted server

### Other Platforms (AWS, Google Cloud, DigitalOcean, etc.)

Any platform that supports Node.js will work. Point it at either a self-hosted
`shoufad` instance or an Upstash-compatible REST endpoint.

```bash
# Build
pnpm build

# Start
pnpm start -p 3000
```

### Environment Variables

| Variable | Required | Description |
| --- | --- | --- |
| `SHOUFA_REDIS_REST_URL` | For self-hosted | Self-hosted server base URL |
| `SHOUFA_REDIS_REST_TOKEN` | For self-hosted | API key from `~/.config/shoufad/config` (manual run) or `/etc/shoufad/config` (systemd install) |
| `UPSTASH_REDIS_REST_URL` | For cloud | Upstash-compatible REST URL |
| `UPSTASH_REDIS_REST_TOKEN` | For cloud | Upstash REST token |
| `UPSTASH_TIER` | Optional | `free` (default), `pro`, or `enterprise` limits |

**Without any storage variables**, the app uses in-process memory (development only).

## License

MIT
