// In-memory Redis mock that emulates real Redis commands
// Used for local development to catch serialization issues early

interface RedisHash {
  [field: string]: string
}

interface RedisKey {
  value: string | RedisHash
  expiresAt?: number
}

export class RedisMock {
  private store: Map<string, RedisKey> = new Map()

  // ============================================================
  // Key commands
  // ============================================================

  async exists(key: string): Promise<number> {
    this.cleanup()
    return this.store.has(key) ? 1 : 0
  }

  async del(...keys: string[]): Promise<number> {
    let deleted = 0
    for (const key of keys) {
      if (this.store.has(key)) {
        this.store.delete(key)
        deleted++
      }
    }
    return deleted
  }

  async expire(key: string, seconds: number): Promise<number> {
    const entry = this.store.get(key)
    if (!entry) return 0
    entry.expiresAt = Date.now() + seconds * 1000
    return 1
  }

  async ttl(key: string): Promise<number> {
    const entry = this.store.get(key)
    if (!entry) return -2 // Key does not exist
    if (!entry.expiresAt) return -1 // Key exists but has no TTL
    const remaining = Math.ceil((entry.expiresAt - Date.now()) / 1000)
    return remaining > 0 ? remaining : -2
  }

  // ============================================================
  // Hash commands
  // ============================================================

  async hset(key: string, ...args: (string | Record<string, string>)[]): Promise<number> {
    this.cleanup()
    let added = 0

    // Get or create hash
    let entry = this.store.get(key)
    if (!entry) {
      entry = { value: {} }
      this.store.set(key, entry)
    }
    let hash = entry.value as RedisHash
    if (typeof hash === "string") {
      // Convert string to hash (shouldn't happen but handle it)
      hash = {}
      entry.value = hash
    }

    // Parse arguments
    for (const arg of args) {
      if (typeof arg === "string") {
        // hset key field value format
        continue // Skip, handled below
      } else if (typeof arg === "object" && arg !== null) {
        // hset key { field: value, ... } format (Upstash style)
        for (const [field, value] of Object.entries(arg)) {
          if (!(field in hash)) added++
          hash[field] = String(value)
        }
      }
    }

    // Handle hset key field value format (ioredis style)
    if (args.length >= 2 && typeof args[0] === "string" && typeof args[1] === "string") {
      for (let i = 0; i < args.length; i += 2) {
        const field = args[i] as string
        const value = args[i + 1] as string
        if (field && value !== undefined) {
          if (!(field in hash)) added++
          hash[field] = value
        }
      }
    }

    return added
  }

  async hgetall(key: string): Promise<Record<string, string>> {
    this.cleanup()
    const entry = this.store.get(key)
    if (!entry) return {}

    const hash = entry.value as RedisHash
    if (typeof hash !== "object" || hash === null) return {}

    // Return a copy (like real Redis)
    return { ...hash }
  }

  async hdel(key: string, ...fields: string[]): Promise<number> {
    this.cleanup()
    const entry = this.store.get(key)
    if (!entry) return 0

    const hash = entry.value as RedisHash
    if (typeof hash !== "object" || hash === null) return 0

    let deleted = 0
    for (const field of fields) {
      if (field in hash) {
        delete hash[field]
        deleted++
      }
    }

    // Clean up empty hashes
    if (Object.keys(hash).length === 0) {
      this.store.delete(key)
    }

    return deleted
  }

  // ============================================================
  // String commands (for completeness)
  // ============================================================

  async get(key: string): Promise<string | null> {
    this.cleanup()
    const entry = this.store.get(key)
    if (!entry) return null
    if (typeof entry.value === "string") return entry.value
    return null
  }

  async set(key: string, value: string, ...args: string[]): Promise<string> {
    let ttl: number | undefined

    // Parse EX/PX arguments
    for (let i = 0; i < args.length; i += 2) {
      if (args[i]?.toUpperCase() === "EX") {
        ttl = parseInt(args[i + 1], 10)
      }
    }

    const entry: RedisKey = { value }
    if (ttl) {
      entry.expiresAt = Date.now() + ttl * 1000
    }

    this.store.set(key, entry)
    return "OK"
  }

  // ============================================================
  // Utility
  // ============================================================

  private cleanup(): void {
    const now = Date.now()
    for (const [key, entry] of this.store) {
      if (entry.expiresAt && now > entry.expiresAt) {
        this.store.delete(key)
      }
    }
  }

  // For debugging
  async dbsize(): Promise<number> {
    this.cleanup()
    return this.store.size
  }

  async flushall(): Promise<string> {
    this.store.clear()
    return "OK"
  }
}

// Singleton instance (persists across requests in same process)
const globalMock = globalThis as typeof globalThis & {
  __redisMock?: RedisMock
}

export function getRedisMock(): RedisMock {
  if (!globalMock.__redisMock) {
    globalMock.__redisMock = new RedisMock()
  }
  return globalMock.__redisMock
}
