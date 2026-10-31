import { getRedisMock, type RedisMock } from "../redis-mock"
import type {
  RedisAdapter,
  RedisHashFields,
  RedisSetOptions,
} from "./types"

/** Local development fallback. Data lives only in this process. */
export class MemoryRedisAdapter implements RedisAdapter {
  readonly kind = "memory" as const

  constructor(private readonly client: RedisMock = getRedisMock()) {}

  async ping(): Promise<boolean> {
    return true
  }

  async exists(key: string): Promise<number> {
    return this.client.exists(key)
  }

  async del(...keys: string[]): Promise<number> {
    return this.client.del(...keys)
  }

  async expire(key: string, seconds: number): Promise<number> {
    return this.client.expire(key, seconds)
  }

  async ttl(key: string): Promise<number> {
    return this.client.ttl(key)
  }

  async hset(key: string, fields: RedisHashFields): Promise<number> {
    return this.client.hset(key, fields)
  }

  async hgetall(key: string): Promise<Record<string, string>> {
    return this.client.hgetall(key)
  }

  async hdel(key: string, ...fields: string[]): Promise<number> {
    return this.client.hdel(key, ...fields)
  }

  async get(key: string): Promise<string | null> {
    return this.client.get(key)
  }

  async set(key: string, value: string, options?: RedisSetOptions): Promise<string> {
    if (options?.ex) {
      return this.client.set(key, value, "EX", String(options.ex))
    }
    return this.client.set(key, value)
  }
}
