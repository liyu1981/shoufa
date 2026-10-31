export type StorageProviderKind = "self-hosted" | "upstash" | "memory"

export type RedisHashFields = Record<string, string | number>

export interface RedisSetOptions {
  /** Expiry in seconds. */
  ex?: number
}

/**
 * Small Redis command surface used by Shoufa.
 *
 * All implementations accept the same object-shaped HSET API so callers do
 * not need to know whether they are talking to the in-memory mock, Upstash, or
 * the self-hosted Zig server.
 */
export interface RedisAdapter {
  readonly kind: StorageProviderKind

  ping(): Promise<boolean>

  exists(key: string): Promise<number>
  del(...keys: string[]): Promise<number>
  expire(key: string, seconds: number): Promise<number>
  ttl(key: string): Promise<number>

  hset(key: string, fields: RedisHashFields): Promise<number>
  hgetall(key: string): Promise<Record<string, string>>
  hdel(key: string, ...fields: string[]): Promise<number>

  get(key: string): Promise<string | null>
  set(key: string, value: string, options?: RedisSetOptions): Promise<string>
}

export interface StorageProviderInfo {
  kind: StorageProviderKind
  /** Human-readable backend name, e.g. "shoufad", "Upstash", "Layerbase". */
  displayName: string
  configured: boolean
  source: "self-hosted" | "cloud" | "dev-memory"
  /** Base URL for REST-backed providers. Never includes the token. */
  url?: string
}
