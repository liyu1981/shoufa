import type { RedisAdapter, StorageProviderInfo } from "./types"

interface RestConfig {
  url: string
  token: string
}

function env(name: string): string | undefined {
  const value = process.env[name]?.trim()
  return value ? value : undefined
}

/**
 * Self-hosted config wins over cloud. Both the canonical names and a shorter
 * alias are accepted to make deployments less error-prone.
 */
export function getSelfHostedConfig(): RestConfig | null {
  const url = env("SHOUFA_REDIS_REST_URL") ?? env("SHOUFA_REDIS_URL")
  const token = env("SHOUFA_REDIS_REST_TOKEN") ?? env("SHOUFA_REDIS_TOKEN")
  return url && token ? { url, token } : null
}

export function getCloudConfig(): RestConfig | null {
  const url = env("UPSTASH_REDIS_REST_URL")
  const token = env("UPSTASH_REDIS_REST_TOKEN")
  return url && token ? { url, token } : null
}

function cloudDisplayName(url: string): string {
  try {
    const host = new URL(url).hostname.toLowerCase()
    if (host === "upstash.io" || host.endsWith(".upstash.io")) return "Upstash"
    if (host === "layerbase.dev" || host.endsWith(".layerbase.dev")) return "Layerbase"
  } catch {
    // Fall through to the generic label.
  }
  return "Upstash-compatible cloud"
}

export function getStorageProviderInfo(): StorageProviderInfo {
  const selfHosted = getSelfHostedConfig()
  if (selfHosted) {
    return {
      kind: "self-hosted",
      displayName: "shoufad",
      configured: true,
      source: "self-hosted",
      url: selfHosted.url,
    }
  }

  const cloud = getCloudConfig()
  if (cloud) {
    return {
      kind: "upstash",
      displayName: cloudDisplayName(cloud.url),
      configured: true,
      source: "cloud",
      url: cloud.url,
    }
  }

  return {
    kind: "memory",
    displayName: "in-memory storage",
    configured: false,
    source: "dev-memory",
  }
}

let cachedAdapter: RedisAdapter | null = null

/**
 * Resolve the storage backend once per process:
 *
 *   1. SHOUFA_REDIS_REST_URL + SHOUFA_REDIS_REST_TOKEN -> self-hosted Zig server
 *   2. UPSTASH_REDIS_REST_URL + UPSTASH_REDIS_REST_TOKEN -> Upstash/cloud
 *   3. neither -> in-process memory (development fallback)
 */
export async function getRedisAdapter(): Promise<RedisAdapter> {
  if (cachedAdapter) return cachedAdapter

  const selfUrl = env("SHOUFA_REDIS_REST_URL") ?? env("SHOUFA_REDIS_URL")
  const selfToken = env("SHOUFA_REDIS_REST_TOKEN") ?? env("SHOUFA_REDIS_TOKEN")
  if (Boolean(selfUrl) !== Boolean(selfToken)) {
    console.warn(
      "[storage] Incomplete self-hosted Redis config: set both " +
        "SHOUFA_REDIS_REST_URL and SHOUFA_REDIS_REST_TOKEN (or neither).",
    )
  }

  const cloudUrl = env("UPSTASH_REDIS_REST_URL")
  const cloudToken = env("UPSTASH_REDIS_REST_TOKEN")
  if (Boolean(cloudUrl) !== Boolean(cloudToken)) {
    console.warn(
      "[storage] Incomplete Upstash Redis config: set both " +
        "UPSTASH_REDIS_REST_URL and UPSTASH_REDIS_REST_TOKEN (or neither).",
    )
  }

  const selfHosted = getSelfHostedConfig()
  if (selfHosted) {
    const { SelfHostedRedisAdapter } = await import("./self-hosted")
    cachedAdapter = new SelfHostedRedisAdapter(selfHosted.url, selfHosted.token)
    return cachedAdapter
  }

  const cloud = getCloudConfig()
  if (cloud) {
    const { UpstashRedisAdapter } = await import("./upstash")
    cachedAdapter = await UpstashRedisAdapter.create(cloud.url, cloud.token)
    return cachedAdapter
  }

  if (process.env.NODE_ENV === "production") {
    console.warn(
      "[storage] No self-hosted or Upstash Redis env vars found; " +
        "falling back to per-process memory. Configure SHOUFA_REDIS_REST_URL/TOKEN " +
        "or UPSTASH_REDIS_REST_URL/TOKEN for production.",
    )
  }

  const { MemoryRedisAdapter } = await import("./memory")
  cachedAdapter = new MemoryRedisAdapter()
  return cachedAdapter
}

/** Useful for tests that need to re-read env vars. */
export function resetRedisAdapter(): void {
  cachedAdapter = null
}
