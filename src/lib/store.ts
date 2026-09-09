// Hybrid store: Redis mock (local dev) or Upstash Redis (production)
// Mock emulates real Redis commands to catch serialization issues early

import { nanoid } from "nanoid"
import { getRedisMock, RedisMock } from "./redis-mock"
import { limits } from "./config"

export interface Asset {
  id: string
  type: "text" | "image"
  content?: string       // for text
  data?: string          // base64 data URL for image
  mimeType?: string
  fileName?: string
  ttl: number            // seconds
  createdAt: number
  expiresAt: number
}

export interface SlugMeta {
  slug: string
  createdAt: number
  [key: string]: string | number
}

// ============================================================
// Mode detection
// ============================================================

function isUpstashRedis(): boolean {
  return !!process.env.UPSTASH_REDIS_REST_URL && !!process.env.UPSTASH_REDIS_REST_TOKEN
}

// ============================================================
// Redis clients (lazy initialization)
// ============================================================

let mockRedis: RedisMock | null = null
let upstashRedis: any = null

async function getRedis() {
  if (isUpstashRedis()) {
    // Production: use Upstash Redis
    if (!upstashRedis) {
      const { Redis } = await import("@upstash/redis")
      upstashRedis = new Redis({
        url: process.env.UPSTASH_REDIS_REST_URL!,
        token: process.env.UPSTASH_REDIS_REST_TOKEN!,
      })
    }
    return upstashRedis
  } else {
    // Development: use mock Redis (emulates real commands)
    if (!mockRedis) {
      mockRedis = getRedisMock()
    }
    return mockRedis
  }
}

// Key patterns
const slugKey = (slug: string) => `slug:${slug}`
const assetsKey = (slug: string) => `slug:${slug}:assets`

// ============================================================
// Unified API (works with both mock and real Redis)
// ============================================================

export async function slugExists(slug: string): Promise<boolean> {
  const r = await getRedis()
  const exists = await r.exists(slugKey(slug))
  return exists === 1
}

export async function createSlug(slug: string): Promise<SlugMeta> {
  const r = await getRedis()
  const meta: SlugMeta = { slug, createdAt: Date.now() }

  if (r instanceof RedisMock) {
    // Mock: use ioredis-style hset with multiple args
    await r.hset(slugKey(slug), "slug", slug, "createdAt", String(meta.createdAt))
  } else {
    // Upstash: use object-style hset
    await r.hset(slugKey(slug), meta)
  }

  await r.expire(slugKey(slug), 3600)
  return meta
}

export async function getSlug(slug: string): Promise<SlugMeta | null> {
  const r = await getRedis()
  const meta = await r.hgetall(slugKey(slug))

  if (!meta || Object.keys(meta).length === 0) return null

  // Normalize: ensure consistent types
  return {
    slug: String(meta.slug),
    createdAt: Number(meta.createdAt),
  } as SlugMeta
}

export async function deleteSlug(slug: string): Promise<boolean> {
  const r = await getRedis()
  const existed = await r.exists(slugKey(slug))
  await r.del(slugKey(slug), assetsKey(slug))
  return existed === 1
}

export async function addAsset(
  slug: string,
  asset: Omit<Asset, "id" | "createdAt" | "expiresAt">
): Promise<Asset | null> {
  const config = limits()

  // Validate TTL
  const ttl = Math.min(asset.ttl, config.maxTtl)

  // Validate image size
  if (asset.type === "image" && asset.data) {
    const sizeInBytes = Math.ceil(asset.data.length * 3 / 4) // Approximate base64 size
    if (sizeInBytes > config.maxImageSize) {
      console.error("[store] Image too large:", sizeInBytes, ">", config.maxImageSize)
      return null
    }
  }

  const id = nanoid(12)
  const now = Date.now()
  const fullAsset: Asset = {
    ...asset,
    ttl,
    id,
    createdAt: now,
    expiresAt: now + ttl * 1000,
  }

  try {
    const r = await getRedis()
    const exists = await r.exists(slugKey(slug))
    if (!exists) return null

    const assetJson = JSON.stringify(fullAsset)
    const keyTTL = Math.ceil(asset.ttl) + 60

    if (r instanceof RedisMock) {
      // Mock: use ioredis-style hset
      await r.hset(assetsKey(slug), id, assetJson)
    } else {
      // Upstash: use object-style hset
      await r.hset(assetsKey(slug), { [id]: assetJson })
    }

    await r.expire(assetsKey(slug), keyTTL)
    await r.expire(slugKey(slug), Math.max(keyTTL, 3600))

    return fullAsset
  } catch (error) {
    console.error("[store] addAsset error:", error)
    return null
  }
}

export async function getAssets(slug: string): Promise<Asset[]> {
  try {
    const r = await getRedis()
    const raw = await r.hgetall(assetsKey(slug))

    if (!raw || typeof raw !== "object" || Object.keys(raw).length === 0) {
      return []
    }

    const now = Date.now()
    const assets: Asset[] = []

    for (const [id, value] of Object.entries(raw)) {
      try {
        const jsonStr = typeof value === "string" ? value : JSON.stringify(value)
        const asset: Asset = JSON.parse(jsonStr)

        if (asset && asset.id && asset.expiresAt) {
          if (asset.expiresAt > now) {
            assets.push(asset)
          } else {
            r.hdel(assetsKey(slug), id).catch(() => {})
          }
        }
      } catch (parseError) {
        console.error("[store] Failed to parse asset:", id, parseError)
      }
    }

    return assets.sort((a, b) => a.createdAt - b.createdAt)
  } catch (error) {
    console.error("[store] getAssets error:", error)
    return []
  }
}

export async function deleteAsset(slug: string, assetId: string): Promise<boolean> {
  const r = await getRedis()
  const deleted = await r.hdel(assetsKey(slug), assetId)
  return deleted > 0
}

export async function isSlugTaken(slug: string): Promise<boolean> {
  return slugExists(slug)
}
