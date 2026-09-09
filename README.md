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
- **Upstash Redis** for serverless storage (Vercel)
- **In-memory store** for local development

## Development

```bash

## Development

```bash
# Install dependencies
pnpm install

# Get a free temporary Upstash Redis (no account needed)
pnpm redis

# Start dev server (HTTPS, port 3210)
pnpm dev

# Open https://localhost:3210
```

**Note:** Local dev uses a real Upstash Redis instance (same as production). Data persists for 3 days. To use in-memory mode instead, comment out the env vars in `.env.local`.

## Deployment

### Vercel (Recommended)

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

   # Deploy to production
   vercel --prod
   ```

Or connect via Vercel Dashboard:
1. Push to GitHub
2. Import project in Vercel
3. Add environment variables from Upstash

### Other Platforms (AWS, Google Cloud, DigitalOcean, etc.)

Any platform that supports Node.js will work. You just need a Redis server for storage.

#### 1. Set up a Redis server

**Option A: Managed Redis (easiest)**
- [Upstash](https://upstash.com) — Serverless, pay-per-request
- [Redis Cloud](https://redis.com/redis-enterprise/cloud) — Free tier available
- [Amazon ElastiCache](https://aws.amazon.com/elasticache/) — AWS managed

**Option B: Self-hosted Redis**
```bash
# On your server
sudo apt install redis-server
sudo systemctl enable redis-server

# Verify it's running
redis-cli ping
# Should return: PONG
```

#### 2. Configure environment variables

Set these on your hosting platform:

```bash
UPSTASH_REDIS_REST_URL=https://your-redis-instance.com
UPSTASH_REDIS_REST_TOKEN=your-token
```

For self-hosted Redis with REST API, use [Lettuce](https://lettuce.io) or [Redis with a REST proxy](https://github.com/nicholasgasior/redis-rest-proxy).

If your Redis uses the standard protocol (not REST), you'll need to modify `src/lib/store.ts` to use a Redis client like `ioredis`.

#### 3. Deploy

```bash
# Build
pnpm build

# Start
pnpm start -p 3000
```

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `UPSTASH_REDIS_REST_URL` | For storage | Redis REST URL |
| `UPSTASH_REDIS_REST_TOKEN` | For storage | Redis REST token |

**Without these variables**, the app uses in-memory storage (data resets on restart).

## License

MIT
