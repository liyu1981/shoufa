// Hybrid store: in-memory for local dev, Upstash Redis for production
// No extra setup needed — just works

import { nanoid } from "nanoid"

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
// In-memory store (for local development)
// ============================================================

interface MemorySpace {
  meta: SlugMeta
  assets: Map<string, Asset>
}

const memoryStore = new Map<string, MemorySpace>()

// Sweep expired assets every 5 seconds (only in memory mode)
let sweepInterval: NodeJS.Timeout | null = null

function startMemorySweep() {
  if (sweepInterval || !isMemoryMode()) return
  sweepInterval = setInterval(() => {
    const now = Date.now()
    for (const [slug, space] of memoryStore) {
      for (const [id, asset] of space.assets) {
        if (now > asset.expiresAt) {
          space.assets.delete(id)
        }
      }
      // Keep empty slugs for 60 seconds
      if (space.assets.size === 0 && now - space.meta.createdAt > 60_000) {
        memoryStore.delete(slug)
      }
    }
  }, 5000)
}

function isMemoryMode(): boolean {
  const url = process.env.UPSTASH_REDIS_REST_URL
  // Memory mode if no URL or if it's still the placeholder
  return !url || url.includes("your-redis.upstash.io")
}

// ============================================================
// Upstash Redis (for production)
// ============================================================

let redisClient: any = null

async function getRedis() {
  if (!redisClient) {
    const { Redis } = await import("@upstash/redis")
    redisClient = new Redis({
      url: process.env.UPSTASH_REDIS_REST_URL!,
      token: process.env.UPSTASH_REDIS_REST_TOKEN!,
    })
  }
  return redisClient
}

const slugKey = (slug: string) => `slug:${slug}`
const assetsKey = (slug: string) => `slug:${slug}:assets`

// ============================================================
// Unified API (works with both backends)
// ============================================================

export async function slugExists(slug: string): Promise<boolean> {
  if (isMemoryMode()) {
    return memoryStore.has(slug)
  }
  const r = await getRedis()
  const exists = await r.exists(slugKey(slug))
  return exists === 1
}

export async function createSlug(slug: string): Promise<SlugMeta> {
  if (isMemoryMode()) {
    const meta: SlugMeta = { slug, createdAt: Date.now() }
    memoryStore.set(slug, { meta, assets: new Map() })
    startMemorySweep()
    return meta
  }
  const r = await getRedis()
  const meta: SlugMeta = { slug, createdAt: Date.now() }
  await r.hset(slugKey(slug), meta)
  await r.expire(slugKey(slug), 3600)
  return meta
}

export async function getSlug(slug: string): Promise<SlugMeta | null> {
  if (isMemoryMode()) {
    const space = memoryStore.get(slug)
    return space?.meta ?? null
  }
  const r = await getRedis()
  const meta = await r.hgetall(slugKey(slug))
  if (!meta || Object.keys(meta).length === 0) return null
  return meta as SlugMeta
}

export async function deleteSlug(slug: string): Promise<boolean> {
  if (isMemoryMode()) {
    return memoryStore.delete(slug)
  }
  const r = await getRedis()
  const existed = await r.exists(slugKey(slug))
  await r.del(slugKey(slug), assetsKey(slug))
  return existed === 1
}

export async function addAsset(
  slug: string,
  asset: Omit<Asset, "id" | "createdAt" | "expiresAt">
): Promise<Asset | null> {
  const id = nanoid(12)
  const now = Date.now()
  const fullAsset: Asset = {
    ...asset,
    id,
    createdAt: now,
    expiresAt: now + asset.ttl * 1000,
  }

  if (isMemoryMode()) {
    const space = memoryStore.get(slug)
    if (!space) return null
    space.assets.set(id, fullAsset)
    return fullAsset
  }

  try {
    const r = await getRedis()
    const exists = await r.exists(slugKey(slug))
    if (!exists) return null

    // Store asset as JSON string
    const assetJson = JSON.stringify(fullAsset)
    await r.hset(assetsKey(slug), { [id]: assetJson })

    // Set TTL based on this asset's expiry only (simpler and reliable)
    const keyTTL = Math.ceil(asset.ttl) + 60 // TTL in seconds + buffer
    await r.expire(assetsKey(slug), keyTTL)
    await r.expire(slugKey(slug), Math.max(keyTTL, 3600))

    return fullAsset
  } catch (error) {
    console.error("[store] addAsset error:", error)
    return null
  }
}

export async function getAssets(slug: string): Promise<Asset[]> {
  if (isMemoryMode()) {
    const space = memoryStore.get(slug)
    if (!space) return []
    const now = Date.now()
    return Array.from(space.assets.values())
      .filter((a) => a.expiresAt > now)
      .sort((a, b) => a.createdAt - b.createdAt)
  }

  try {
    const r = await getRedis()
    const raw = await r.hgetall(assetsKey(slug))

    // Debug logging
    console.log("[store] getAssets raw:", JSON.stringify(raw).substring(0, 200))

    if (!raw || typeof raw !== "object" || Object.keys(raw).length === 0) {
      return []
    }

    const now = Date.now()
    const assets: Asset[] = []

    for (const [id, value] of Object.entries(raw)) {
      try {
        // Upstash might return the value as a string or as a parsed object
        const jsonStr = typeof value === "string" ? value : JSON.stringify(value)
        const asset: Asset = JSON.parse(jsonStr)

        // Validate asset structure
        if (asset && asset.id && asset.expiresAt) {
          if (asset.expiresAt > now) {
            assets.push(asset)
          } else {
            // Clean up expired asset
            r.hdel(assetsKey(slug), id).catch(() => {})
          }
        }
      } catch (parseError) {
        console.error("[store] Failed to parse asset:", id, parseError)
        // Don't delete on parse error - might be temporary
      }
    }

    return assets.sort((a, b) => a.createdAt - b.createdAt)
  } catch (error) {
    console.error("[store] getAssets error:", error)
    return []
  }
}

export async function deleteAsset(slug: string, assetId: string): Promise<boolean> {
  if (isMemoryMode()) {
    const space = memoryStore.get(slug)
    if (!space) return false
    return space.assets.delete(assetId)
  }

  const r = await getRedis()
  const deleted = await r.hdel(assetsKey(slug), assetId)
  return deleted > 0
}

export async function isSlugTaken(slug: string): Promise<boolean> {
  return slugExists(slug)
}
