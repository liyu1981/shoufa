/** Upstash returns HGETALL as an object; some REST-compatible servers return
 * a flat [field, value, ...] array. Normalize both to a plain object. */
export function normalizeHash(raw: unknown): Record<string, string> {
  if (!raw) return {}

  if (Array.isArray(raw)) {
    const result: Record<string, string> = {}
    for (let i = 0; i < raw.length; i += 2) {
      const field = raw[i]
      const value = raw[i + 1]
      if (field === undefined) continue
      result[String(field)] = value === undefined || value === null ? "" : String(value)
    }
    return result
  }

  if (typeof raw === "object") {
    const result: Record<string, string> = {}
    for (const [field, value] of Object.entries(raw as Record<string, unknown>)) {
      result[field] = typeof value === "string" ? value : JSON.stringify(value)
    }
    return result
  }

  return {}
}
