/**
 * Format bytes to human readable string
 */
export function formatBytes(bytes: number): string {
  if (bytes === 0) return "0 B"
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`
}

/**
 * Get asset size in bytes (approximate for text)
 */
export function getAssetSize(asset: {
  type: string
  content?: string
  data?: string
  size?: number
}): number {
  if (asset.size) return asset.size
  if (asset.type === "text" && asset.content) {
    return new TextEncoder().encode(asset.content).length
  }
  if (asset.data) {
    // Approximate: data URL is ~33% larger than original
    // Remove "data:...;base64," prefix to get raw base64
    const base64 = asset.data.split(",")[1] || ""
    return Math.floor(base64.length * 0.75)
  }
  return 0
}
