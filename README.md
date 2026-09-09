# Shoufa

**Paste. Share. Disappear.**

An ephemeral clipboard with a time limit. Paste text or images, share the link, and watch it auto-expire.

## Features

- 🎨 **Apple Glass Design** — Frosted glass surfaces with ambient animated background
- ⏱️ **TTL** — Assets expire after 1min–1hr (configurable per paste)
- 📋 **Easy Copy/Download** — One-click copy text, one-click download images
- 🎲 **Memorable Slugs** — Auto-generated `adjective-noun` combos (e.g., `bright-fox`, `calm-pond`)
- 🌙 **Dark Mode** — Automatic light/dark theme support

## Tech Stack

- **Next.js 16** (App Router)
- **TypeScript**
- **Tailwind CSS v4** + Apple glass design system
- **Jotai** for state management
- **Upstash Redis** for serverless-compatible storage

## Quick Start

### Development

```bash
# Install dependencies
pnpm install

# Start dev server
pnpm dev
```

### Deployment to Vercel

1. **Create Upstash Redis**:
   - Go to [Upstash Console](https://console.upstash.com)
   - Create a new Redis database (free tier: 10,000 commands/day)
   - Copy the `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`

2. **Deploy to Vercel**:
   ```bash
   # Install Vercel CLI
   pnpm add -g vercel

   # Deploy
   vercel

   # Add environment variables
   vercel env add UPSTASH_REDIS_REST_URL
   vercel env add UPSTASH_REDIS_REST_TOKEN

   # Deploy to production
   vercel --prod
   ```

3. **Or connect via Vercel Dashboard**:
   - Push to GitHub
   - Import project in Vercel
   - Add environment variables from Upstash

### Environment Variables

| Variable | Description |
|----------|-------------|
| `UPSTASH_REDIS_REST_URL` | Upstash Redis REST URL |
| `UPSTASH_REDIS_REST_TOKEN` | Upstash Redis REST token |

## Project Structure

```
shoufa/
├── src/
│   ├── app/
│   │   ├── page.tsx              ← Landing: join or create slug
│   │   ├── s/[slug]/page.tsx     ← Slug space: paste, view, copy, download
│   │   └── api/
│   │       ├── slugs/route.ts    ← POST: create slug
│   │       └── [slug]/
│   │           ├── route.ts      ← DELETE: destroy slug
│   │           ├── exists/       ← GET: check if slug exists
│   │           └── assets/       ← GET/POST/DELETE: manage assets
│   ├── components/
│   │   ├── AmbientBackground.tsx ← Animated canvas blobs
│   │   ├── GlassCard.tsx         ← Glass-control wrapper
│   │   ├── PasteZone.tsx         ← Ctrl+V / drag-drop zone
│   │   ├── AssetCard.tsx         ← Text/Image display
│   │   └── CountdownTimer.tsx    ← TTL countdown
│   └── lib/
│       ├── slugs.ts              ← Slug generator (40k+ combos)
│       ├── store.ts              ← Upstash Redis store
│       └── utils.ts              ← cn() helper
```

## API

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/slugs` | Create slug (auto or custom) |
| `GET` | `/api/[slug]/assets` | List all assets |
| `POST` | `/api/[slug]/assets` | Add text/image |
| `DELETE` | `/api/[slug]/assets/[id]` | Delete asset |
| `DELETE` | `/api/[slug]` | Destroy slug |

## License

MIT
