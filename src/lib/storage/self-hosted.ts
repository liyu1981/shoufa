import { normalizeHash } from "./normalize"
import type {
  RedisAdapter,
  RedisHashFields,
  RedisSetOptions,
} from "./types"

const REQUEST_TIMEOUT_MS = 15_000

export class RedisRestError extends Error {
  constructor(
    message: string,
    readonly status?: number,
  ) {
    super(message)
    this.name = "RedisRestError"
  }
}

/**
 * Client for the self-hosted Zig server (`server/`).
 *
 * The wire format is Upstash-compatible: POST a JSON command array to the
 * root, or POST an array of command arrays to `/pipeline`.
 */
export class SelfHostedRedisAdapter implements RedisAdapter {
  readonly kind = "self-hosted" as const
  private readonly baseUrl: string
  private readonly token: string

  constructor(url: string, token: string) {
    this.baseUrl = url.replace(/\/+$/, "")
    this.token = token
  }

  async ping(): Promise<boolean> {
    const result = await this.command(["PING"])
    return result === "PONG"
  }

  async exists(key: string): Promise<number> {
    return Number(await this.command(["EXISTS", key])) || 0
  }

  async del(...keys: string[]): Promise<number> {
    if (keys.length === 0) return 0
    return Number(await this.command(["DEL", ...keys])) || 0
  }

  async expire(key: string, seconds: number): Promise<number> {
    return Number(await this.command(["EXPIRE", key, String(seconds)])) || 0
  }

  async ttl(key: string): Promise<number> {
    return Number(await this.command(["TTL", key]))
  }

  async hset(key: string, fields: RedisHashFields): Promise<number> {
    const args: string[] = []
    for (const [field, value] of Object.entries(fields)) {
      args.push(field, String(value))
    }
    if (args.length === 0) return 0
    return Number(await this.command(["HSET", key, ...args])) || 0
  }

  async hgetall(key: string): Promise<Record<string, string>> {
    return normalizeHash(await this.command(["HGETALL", key]))
  }

  async hdel(key: string, ...fields: string[]): Promise<number> {
    if (fields.length === 0) return 0
    return Number(await this.command(["HDEL", key, ...fields])) || 0
  }

  async get(key: string): Promise<string | null> {
    const result = await this.command(["GET", key])
    return result === null || result === undefined ? null : String(result)
  }

  async set(key: string, value: string, options?: RedisSetOptions): Promise<string> {
    const args = ["SET", key, value]
    if (options?.ex) args.push("EX", String(options.ex))
    return String((await this.command(args)) ?? "OK")
  }

  private async command(args: string[]): Promise<unknown> {
    const response = await fetch(this.baseUrl, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${this.token}`,
      },
      body: JSON.stringify(args),
      cache: "no-store",
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    })

    const payload = (await response.json().catch(() => null)) as
      | { result?: unknown; error?: string }
      | null

    if (!response.ok || payload?.error) {
      throw new RedisRestError(
        payload?.error || `Redis REST request failed (${response.status})`,
        response.status,
      )
    }

    return payload?.result
  }
}
