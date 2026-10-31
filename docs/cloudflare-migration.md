# Migrating Shoufa to Cloudflare — Feasibility & Cost Research

**App:** Shoufa (Next.js 16 App Router, ephemeral clipboard)
**Date:** 2026-10-27
**Current host:** Vercel (Hobby) + Upstash Redis (free tier)

> **Update — self-hosted storage:** the repo now includes a Zig-based
> Redis-compatible REST server in [`server/`](../server/README.md). Set
> `SHOUFA_REDIS_REST_URL` + `SHOUFA_REDIS_REST_TOKEN` and the app prefers it
> over Upstash; otherwise it falls back to the cloud provider. See
> [`docs/self-hosted-redis.md`](./self-hosted-redis.md).

## 1. Summary

- **Feasibility: High.** The app builds and runs on Cloudflare Workers. The recommended path is the **OpenNext Cloudflare adapter** (`@opennextjs/cloudflare`), which keeps the existing Next.js 16 codebase unchanged. A build + local preview + full page render were verified successfully.
- **Cost: ~$5/month** for production (Workers Paid plan), down from Vercel Pro's $20/month, or $0 on free tiers with CPU caveats. Storage (Upstash Redis) can stay as-is.
- **One blocker for the alternative `vinext` path:** `@next/third-parties/google` (used for Google Analytics) is a TS-compiled CJS module and breaks SSR under `vinext + @cloudflare/vite-plugin`. Workaround: replace `<GoogleAnalytics />` with a hand-written `<script>` tag. The OpenNext path does **not** have this issue.

## 2. Architecture of the app

| Area | Detail |
| --- | --- |
| Framework | Next.js 16.3.4 (App Router), React 19.2.8 |
| Runtime code | 8 API route handlers (all `force-dynamic`), 2 pages, 1 layout |
| Node APIs used | `Buffer.from(...).toString("base64")` in `src/app/api/[slug]/assets/route.ts` |
| Storage | Upstash Redis REST (`@upstash/redis`) with an in-memory mock for local dev |
| Other deps | `next/font/google` (Geist), `@next/third-parties/google`, Tailwind v4, i18n, Jotai, `next-themes` |
| Image handling | Manual base64 data URLs; **no** `next/image` usage |
| Caching/ISR | None — everything is dynamic |
| Vercel-specific | `vercel.json` (region `iad1`, 10s function max duration) |

Nothing in the app is Vercel-locked: no `@vercel/*` imports, no Vercel KV/Blob, no Edge Config.

## 3. Feasibility

### 3.1 Recommended path — OpenNext Cloudflare adapter

Verified in a copy of the repo:

1. `npx @opennextjs/cloudflare migrate` + manual config (`open-next.config.ts`, `wrangler.jsonc`).
2. `opennextjs-cloudflare build` → **success** ("OpenNext build complete.").
3. `opennextjs-cloudflare preview` (workerd) → app served on `http://localhost:8787`, homepage returned **HTTP 200** with Google Analytics intact.
4. `wrangler deploy --dry-run` → **success**, total upload **5.4 MB / gzip 1.1 MB**, well under the 10 MB Workers limit.

Required config files (new, no app code changes):

`open-next.config.ts`
```ts
import { defineCloudflareConfig } from "@opennextjs/cloudflare";
export default defineCloudflareConfig({});
```

`wrangler.jsonc`
```jsonc
{
  "main": ".open-next/worker.js",
  "name": "shoufa",
  "compatibility_date": "2026-10-26",
  "compatibility_flags": ["nodejs_compat", "global_fetch_strictly_public"],
  "assets": { "directory": ".open-next/assets", "binding": "ASSETS" },
  "services": [{ "binding": "WORKER_SELF_REFERENCE", "service": "shoufa" }]
}
```

`next.config.ts` — add `initOpenNextCloudflareForDev()` for local bindings.

Scripts to add:
```json
"build:opennext": "opennextjs-cloudflare build",
"preview:opennext": "opennextjs-cloudflare preview",
"deploy:opennext": "opennextjs-cloudflare deploy"
```

### 3.2 Alternative path — vinext

Cloudflare's newer recommended path (`vinext`). Compatibility check reported **100% compatible** and `vite build` succeeded. However:

- Requires bumping **React to 19.3.1+** (vinext requirement; current is 19.2.8).
- Known bug ([#1219](https://github.com/cloudflare/vinext/issues/1219)): TS-compiled CJS modules from `node_modules` (including `@next/third-parties/google`) break SSR under `vinext + @cloudflare/vite-plugin`. Workaround: replace `<GoogleAnalytics />` with a manual `<script async src="https://www.googletagmanager.com/gtag/js?id=...">`.
- `vinext` is newer/less battle-tested than OpenNext. Recommend OpenNext for production now; revisit vinext later.

### 3.3 Component-by-component feasibility

| Component | OpenNext | Notes |
| --- | --- | --- |
| App Router, route handlers, middleware | ✅ | Full Node.js runtime via `nodejs_compat` |
| `Buffer` (base64 upload) | ✅ | Available through `nodejs_compat` |
| Upstash Redis (`@upstash/redis`) | ✅ | Fetch-based; works unchanged in Workers |
| `next/font/google` (Geist) | ✅ | Self-hosted by Next/OpenNext |
| `@next/third-parties/google` (GA) | ✅ OpenNext / ⚠️ vinext | Works on OpenNext; breaks on vinext (see 3.2) |
| Tailwind v4, i18n, Jotai, next-themes | ✅ | No changes |
| Service worker (`public/sw.js`) | ✅ | Static asset |
| `robots.ts`, `sitemap.ts`, `manifest.ts` | ✅ | Metadata routes supported |
| Image optimization (`next/image`) | N/A | App doesn't use `next/image`; no Cloudflare Images needed |
| ISR / `use cache` | N/A | App is fully dynamic; no cache to configure |
| Environment variables | ⚠️ | Must be set in Cloudflare (dashboard/secrets); `NEXT_PUBLIC_*` must be present at **build** time |

### 3.4 Runtime constraints to be aware of

- **Memory: 128 MB per isolate (fixed)** vs Vercel's configurable up to 4 GB. The app's largest in-memory payload is a base64 data URL of a 5 MB file (~6.7 MB string) — comfortable.
- **CPU time: 10 ms (free) / 30 s default, up to 5 min (paid)** per request. Encoding a 5 MB file to base64 is well under 30 s but **will exceed the 10 ms free-tier limit**. → Production should use the Paid plan, or reduce `maxImageSize`.
- **Subrequests: 50 (free) / 10,000 (paid)** per invocation. Each API call makes 1–3 Upstash Redis calls — fine.
- **Request body size:** 100 MB limit — above the app's 5–10 MB caps.
- **Bundle size:** 3 MB (free) / 10 MB (paid) compressed. Measured upload is 1.1 MB gzipped — fine.
- **Execution location:** Workers run globally by default. Upstash Redis is regional, so consider Cloudflare **Smart Placement** to co-locate the Worker with the Redis instance and reduce round trips.
- **Upstash Redis as an external dependency:** keeps working, but adds an external fetch per request. Optionally migrate storage to Cloudflare KV/D1/R2 later for lower latency and to remove the Upstash bill.

## 4. Cost

### 4.1 Cloudflare (target)

| Item | Free tier | Paid (recommended) |
| --- | --- | --- |
| Workers compute | $0 — 100k req/day, 10 ms CPU/req | **$5/mo** minimum — 10M req + 30M CPU ms/mo included; +$0.30/M req, +$0.02/M CPU ms |
| Memory | 128 MB (fixed) | 128 MB (fixed) |
| Bundle size | 3 MB | 10 MB |
| Static assets | Included | Included |
| Bandwidth/egress | No separate charge | No separate charge |
| Durable Objects / KV / R2 | Not used (cache disabled) | Not used |
| Cloudflare Images | Not used (no `next/image`) | Not used |
| Custom domain + DNS | Free | Free |
| Analytics | Free (basic) | Free |

**Storage (unchanged):** Upstash Redis — free tier 10k commands/day (256 MB); paid from ~$0.2 / 100k commands if exceeded.

**Estimated monthly for this app on Cloudflare:** **$5** (Workers Paid) + $0 Upstash (if under 10k cmds/day) = **~$5/month**. $0 if traffic stays within free CPU limits and uploads are small.

### 4.2 Current (Vercel)

| Item | Hobby | Pro |
| --- | --- | --- |
| Compute | $0 — 10s wall-clock max duration | $20/mo — 60s–800s duration |
| Bandwidth | 100 GB | 1 TB |
| Storage | Upstash (same as above) | Upstash |

### 4.3 Comparison

| | Vercel (current) | Cloudflare (proposed) |
| --- | --- | --- |
| Compute price | $0 (Hobby) / $20 (Pro) | $0 (free) / $5 (Paid) |
| Upload CPU headroom | 10s wall (Hobby) | 30s CPU (Paid) — but 10ms on free |
| Memory | Up to 4 GB | 128 MB fixed |
| Global execution | Regional (you pick) | Global by default |
| Egress | Counted in bandwidth | No separate charge |
| Cold starts | Possible | Effectively none (isolates) |
| Framework support | Native (Vercel owns Next.js) | Via OpenNext adapter (small lag on new Next.js features) |

**Bottom line:** Cloudflare is cheaper for sustained production use ($5 vs $20) and better for global, compute-light traffic, but gives up configurable memory and native Next.js feature parity. For this app — small payloads, no ISR, no `next/image`, no long CPU jobs — Cloudflare is a good fit.

## 5. Migration plan (high level)

1. Add `@opennextjs/cloudflare` and create `open-next.config.ts`, `wrangler.jsonc`, update `next.config.ts` with `initOpenNextCloudflareForDev()`.
2. Add build/preview/deploy scripts; remove reliance on `vercel.json`.
3. Move env vars (`UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN`, `NEXT_PUBLIC_SITE_URL`, `NEXT_PUBLIC_GA_ID`, `UPSTASH_TIER`) into Cloudflare (dashboard or `wrangler secret`); ensure `NEXT_PUBLIC_*` are available at build time (Workers Builds).
4. (Optional) Replace Google Analytics with a manual gtag `<script>` if switching to the vinext path.
5. Set up a Cloudflare custom domain; update `NEXT_PUBLIC_SITE_URL`.
6. Deploy with `opennextjs-cloudflare deploy`; verify Redis connectivity and asset upload/download.
7. (Optional) Enable Smart Placement if Upstash latency matters.

## 6. Risks / open items

- OpenNext adapter lags Vercel on brand-new Next.js features (e.g., Node.js middleware is not supported by the adapter; this app doesn't use it).
- Keeping Upstash Redis as an external service adds a fetch per request and a regional dependency; consider Cloudflare KV/D1/R2 later.
- Free tier's 10 ms CPU limit will reject large uploads; use Paid plan or lower `maxImageSize`.
- `initOpenNextCloudflareForDev()` is required for local bindings; without it, local dev against real R2/KV won't work (not needed here since we keep Upstash).

## 7. Recommendation

**Proceed with the OpenNext Cloudflare adapter.** It required zero application code changes, built and rendered successfully, and fits the app's dynamic, small-payload profile. Budget **$5/month** (Workers Paid) to avoid the free-tier CPU limit on uploads. Revisit `vinext` once the CJS-module SSR bug (#1219) is resolved, since it produces a much smaller bundle.

## 8. Hybrid option: keep Vercel, use Durable Objects as storage

Short answer: **feasible, but not recommended.** It turns a simple storage swap into a cross-cloud architecture with an intermediary Worker and a near-total rewrite of `src/lib/store.ts`.

### 8.1 Why it isn't a drop-in swap

Durable Objects are **not** a generic database. They are JavaScript objects that run only inside the Cloudflare Workers runtime and are reached through **bindings** (`env.MY_DO`), not a public REST API. A Vercel Function has no access to those bindings. So the shape would be:

```
Vercel (Next.js)  --HTTP-->  Cloudflare Worker (proxy)  --binding-->  Durable Object (SQLite)
```

That means building, deploying, and operating a **second service** (the Worker) in addition to the Vercel app, plus auth (shared secret) between Vercel and the Worker, plus retry/error handling on the Vercel side for an extra network hop.

### 8.2 Data-model rewrite required

The current store (`src/lib/store.ts`) is built on Redis commands (`hset`/`hgetall`/`hdel`/`exists`/`expire`/`del`). Durable Objects use SQLite (or a KV-style storage API) inside the object. You would need to:

- Reimplement slug meta + assets as SQLite tables inside a DO class.
- Replace Redis TTL with Durable Object **alarms** (`setAlarm`) for the 15-minute grace period and asset expiry (or check-on-read + alarm cleanup).
- Handle the single-threaded-per-instance model: one DO instance per slug (`idFromName(slug)`) gives strong consistency and natural isolation — a good fit for "spaces", but you now own concurrency/lifecycle logic.
- Re-point every store function to `fetch()` the proxy Worker instead of calling `@upstash/redis`.

Roughly the entire `store.ts` (~250 lines) and all route handlers' error paths change.

### 8.3 Latency

Every API call gains a Vercel → Cloudflare → DO round trip (typically 50–150 ms). The client polls `/api/[slug]/assets` and `/status` every 2 s, so the extra hop is visible but tolerable. Upstash today is also external, so this is comparable — but you're adding a hop you control and must keep healthy.

### 8.4 Cost

Durable Objects require the **Workers Paid plan ($5/mo minimum)** to be practical (free tier: 100k req/day, 13,000 GB-s/day, 5 GB storage). On top of that:

| Item | Included (Paid) | Overage |
| --- | --- | --- |
| DO requests | 1M/mo | $0.15/M |
| DO duration | 400,000 GB-s/mo | $12.50/M GB-s |
| DO SQLite storage | 5 GB-month | $0.20/GB-month |
| DO rows read | 25B/mo | $0.001/M |
| DO rows written | 50M/mo | $1.00/M |
| Workers compute (proxy) | 10M req + 30M CPU ms | $0.30/M req |

For this app's traffic, everything stays inside the included allocations, so the hybrid costs **~$5/mo for Cloudflare** — **on top of** whatever Vercel charges ($0 Hobby / $20 Pro). Total: **$5 (Hobby) or $25 (Pro) per month**, versus $5 for a full Cloudflare migration or $0/$20 staying on Upstash.

### 8.5 When would the hybrid make sense?

Honestly, rarely for this app. Consider it only if you specifically need Durable Objects' guarantees (strongly consistent per-entity state, WebSockets, alarms) or want to eliminate the Upstash bill while keeping Vercel for other reasons. For pure cost or simplicity, pick one platform:

- **Stay on Vercel + Upstash** — simplest, $0 (Hobby) or $20 (Pro).
- **Migrate fully to Cloudflare (OpenNext)** — cheapest production path, ~$5/mo, single platform.