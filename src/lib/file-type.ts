/** Image MIME types inferred from common file extensions. */
const IMAGE_MIME_BY_EXTENSION: Record<string, string> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  avif: "image/avif",
  svg: "image/svg+xml",
  bmp: "image/bmp",
  ico: "image/x-icon",
}

/**
 * Some browsers/OS file pickers leave `File.type` empty (especially for files
 * dragged from certain apps). Fall back to the extension so an image is not
 * silently stored as a generic file.
 */
export function getEffectiveMimeType(file: File): string {
  const reportedType = file.type.toLowerCase()
  if (reportedType && reportedType !== "application/octet-stream") {
    return reportedType
  }

  const extension = file.name.split(".").pop()?.toLowerCase()
  return extension ? IMAGE_MIME_BY_EXTENSION[extension] ?? "" : ""
}

export function isImageFile(file: File): boolean {
  return getEffectiveMimeType(file).startsWith("image/")
}
