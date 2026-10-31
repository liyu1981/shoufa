import type { Redis } from "@upstash/redis"
import { normalizeHash } from "./normalize"
import type {
  RedisAdapter,
  RedisHashFields,
  RedisSetOptions,
} from "./types"

/** Upstash Redis (or any Upstash-compatible cloud endpoint). */
export class UpstashRedisAdapter implements RedisAdapter {
  readonly kind = "upstash" as const

  constructor(private readonly redis: Redis) {}

  static async create(url: string, token: string): Promise<UpstashRedisAdapter> {
    const { Redis } = await import("@upstash/redis")
    return new UpstashRedisAdapter(new Redis({ url, token }))
  }

  async ping(): Promise<boolean> {
    const result = await this.redis.ping()
    return result === "PONG"
  }

  async exists(key: string): Promise<number> {
    return this.redis.exists(key)
  }

  async del(...keys: string[]): Promise<number> {
    if (keys.length === 0) return 0
    return this.redis.del(...keys)
  }

  async expire(key: string, seconds: number): Promise<number> {
    return this.redis.expire(key, seconds)
  }

  async ttl(key: string): Promise<number> {
    return this.redis.ttl(key)
  }

  async hset(key: string, fields: RedisHashFields): Promise<number> {
    return this.redis.hset(key, fields)
  }

  async hgetall(key: string): Promise<Record<string, string>> {
    return normalizeHash(await this.redis.hgetall(key))
  }

  async hdel(key: string, ...fields: string[]): Promise<number> {
    if (fields.length === 0) return 0
    return this.redis.hdel(key, ...fields)
  }

  async get(key: string): Promise<string | null> {
    return this.redis.get<string>(key)
  }

  async set(key: string, value: string, options?: RedisSetOptions): Promise<string> {
    const result = await this.redis.set(
      key,
      value,
      options?.ex ? { ex: options.ex } : undefined,
    )
    return String(result ?? "OK")
  }
}
