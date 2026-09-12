/**
 * Client-side image optimization using Canvas API.
 * Supports JPEG, WebP, and PNG. Other formats are returned as-is.
 */



/** MIME types we can optimize via Canvas */
const OPTIMIZABLE_TYPES = new Set(["image/jpeg", "image/webp", "image/png"])

/** Whether a file is eligible for client-side optimization */
export function isOptimizable(file: File): boolean {
  return OPTIMIZABLE_TYPES.has(file.type)
}

/** Human-readable file size */
export function humanSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`
}

/**
 * Decode a File into an HTMLImageElement.
 * Returns the image and its natural dimensions.
 */
function decodeImage(file: File): Promise<{ img: HTMLImageElement; width: number; height: number }> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve({ img, width: img.naturalWidth, height: img.naturalHeight })
    img.onerror = () => reject(new Error("Failed to decode image"))
    img.src = URL.createObjectURL(file)
  })
}

/**
 * Draw an image onto a canvas and return a data URL (synchronous, fast).
 * The string length is a close proxy for file size.
 */
function renderToDataUrl(
  img: HTMLImageElement,
  width: number,
  height: number,
  mimeType: string,
  quality: number,
): string {
  const canvas = document.createElement("canvas")
  canvas.width = width
  canvas.height = height
  const ctx = canvas.getContext("2d")
  if (!ctx) return ""

  ctx.imageSmoothingEnabled = true
  ctx.imageSmoothingQuality = "high"
  ctx.drawImage(img, 0, 0, width, height)

  return canvas.toDataURL(mimeType, mimeType === "image/png" ? undefined : quality)
}

/** Estimate file size in bytes from a data URL string. */
function estimateSizeFromDataUrl(dataUrl: string): number {
  // data:image/jpeg;base64,XXXX... → base64 part is after the comma
  const base64 = dataUrl.split(",")[1] || ""
  return Math.ceil(base64.length * 0.75)
}

/**
 * Pick the best output MIME type.
 * Prefer WebP if the browser supports it (smaller), otherwise keep original type.
 */
function bestOutputMime(originalType: string): string {
  if (originalType === "image/webp") return "image/webp"
  if (originalType === "image/png") return "image/png"
  // For JPEG originals, try WebP first
  if (typeof document !== "undefined") {
    const canvas = document.createElement("canvas")
    if (canvas.toDataURL("image/webp").indexOf("data:image/webp") === 0) {
      return "image/webp"
    }
  }
  return "image/jpeg"
}

/**
 * Scale/quality presets keyed by option ID.
 */
const PRESETS: Record<string, { scale: number; quality: number }> = {
  compress: { scale: 1, quality: 0.72 },
  resize75: { scale: 0.75, quality: 0.72 },
  resize50: { scale: 0.5, quality: 0.72 },
  resize33: { scale: 0.33, quality: 0.72 },
}

/**
 * Estimate output sizes for each option (fast, uses toDataURL).
 * Returns a map of optionId → estimated bytes.
 */
export async function estimateOptionSizes(
  file: File,
): Promise<Record<string, number>> {
  const { img, width, height } = await decodeImage(file)
  const outMime = bestOutputMime(file.type)
  const results: Record<string, number> = {}

  for (const [id, preset] of Object.entries(PRESETS)) {
    const w = Math.round(width * preset.scale)
    const h = Math.round(height * preset.scale)
    if (w < 100 || h < 100) continue
    const dataUrl = renderToDataUrl(img, w, h, outMime, preset.quality)
    results[id] = estimateSizeFromDataUrl(dataUrl)
  }

  URL.revokeObjectURL(img.src)
  return results
}

/**
 * Produce the final optimized file from an option ID.
 * Decodes the image, applies the preset, and returns a new File.
 */
export async function optimizeImage(
  file: File,
  optionId: string,
): Promise<File> {
  const preset = PRESETS[optionId]
  if (!preset) throw new Error(`Unknown option: ${optionId}`)

  const { img, width, height } = await decodeImage(file)
  const outMime = bestOutputMime(file.type)
  const w = Math.round(width * preset.scale)
  const h = Math.round(height * preset.scale)

  const blob = await new Promise<Blob>((resolve, reject) => {
    const canvas = document.createElement("canvas")
    canvas.width = w
    canvas.height = h
    const ctx = canvas.getContext("2d")
    if (!ctx) return reject(new Error("Canvas not supported"))
    ctx.imageSmoothingEnabled = true
    ctx.imageSmoothingQuality = "high"
    ctx.drawImage(img, 0, 0, w, h)
    canvas.toBlob(
      (b) => (b ? resolve(b) : reject(new Error("toBlob failed"))),
      outMime,
      outMime === "image/png" ? undefined : preset.quality,
    )
  })

  URL.revokeObjectURL(img.src)

  const ext = outMime.split("/")[1] || "jpg"
  const baseName = file.name.replace(/\.[^.]+$/, "")

  return new File([blob], `${baseName}-optimized.${ext}`, {
    type: outMime,
    lastModified: Date.now(),
  })
}
