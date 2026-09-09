// Upstash Redis tier configuration
// Defaults to free tier limits, override via UPSTASH_LIMITS env var

export interface UpstashLimits {
  /** Max commands per second */
  commandsPerSecond: number
  /** Max request size in bytes */
  requestSize: number
  /** Max record size in bytes */
  recordSize: number
  /** Max data size in bytes */
  dataSize: number
  /** Max monthly bandwidth in bytes */
  monthlyBandwidth: number
  /** Max TTL for assets in seconds */
  maxTtl: number
  /** Max image size in bytes (derived from request size) */
  maxImageSize: number
}

// Free tier defaults (from Upstash pricing page)
const FREE_TIER: UpstashLimits = {
  commandsPerSecond: 10_000,
  requestSize: 10 * 1024 * 1024,      // 10 MB
  recordSize: 100 * 1024 * 1024,      // 100 MB
  dataSize: 256 * 1024 * 1024,        // 256 MB
  monthlyBandwidth: 50 * 1024 * 1024 * 1024, // 50 GB
  maxTtl: 3600,                        // 1 hour max
  maxImageSize: 5 * 1024 * 1024,       // 5 MB (safe limit under 10 MB request)
}

// Paid tier presets
const PAID_TIERS: Record<string, Partial<UpstashLimits>> = {
  pro: {
    commandsPerSecond: 10_000,
    requestSize: 10 * 1024 * 1024,
    recordSize: 100 * 1024 * 1024,
    dataSize: 10 * 1024 * 1024 * 1024, // 10 GB
    monthlyBandwidth: 200 * 1024 * 1024 * 1024, // 200 GB
    maxTtl: 86400,                      // 24 hours
    maxImageSize: 10 * 1024 * 1024,     // 10 MB
  },
  enterprise: {
    commandsPerSecond: 100_000,
    requestSize: 512 * 1024 * 1024,     // 512 MB
    recordSize: 512 * 1024 * 1024,      // 512 MB
    dataSize: 1024 * 1024 * 1024 * 1024, // 1 TB
    monthlyBandwidth: 1024 * 1024 * 1024 * 1024, // 1 TB
    maxTtl: 604800,                     // 7 days
    maxImageSize: 100 * 1024 * 1024,    // 100 MB
  },
}

/**
 * Get Upstash limits from environment or use defaults
 *
 * Set UPSTASH_LIMITS env var to override:
 *   UPSTASH_LIMITS='{"commandsPerSecond":10000,"maxTtl":3600}'
 *
 * Or use a tier preset:
 *   UPSTASH_TIER=free  (default)
 *   UPSTASH_TIER=pro
 *   UPSTASH_TIER=enterprise
 */
export function getLimits(): UpstashLimits {
  const tier = process.env.UPSTASH_TIER || "free"
  let base = { ...FREE_TIER }

  // Apply tier preset if not free
  if (tier !== "free" && PAID_TIERS[tier]) {
    base = { ...base, ...PAID_TIERS[tier] }
  }

  // Apply custom overrides from JSON env var
  const customLimits = process.env.UPSTASH_LIMITS
  if (customLimits) {
    try {
      const parsed = JSON.parse(customLimits)
      base = { ...base, ...parsed }
    } catch (e) {
      console.warn("[config] Failed to parse UPSTASH_LIMITS:", e)
    }
  }

  return base
}

// Singleton
let cachedLimits: UpstashLimits | null = null

export function limits(): UpstashLimits {
  if (!cachedLimits) {
    cachedLimits = getLimits()
  }
  return cachedLimits
}

// Human-readable format for display
export function formatLimits(): string {
  const l = limits()
  return `Tier: ${process.env.UPSTASH_TIER || "free"} | ` +
    `Commands: ${l.commandsPerSecond}/s | ` +
    `Max image: ${formatBytes(l.maxImageSize)} | ` +
    `Max TTL: ${l.maxTtl}s | ` +
    `Data: ${formatBytes(l.dataSize)}`
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`
}
