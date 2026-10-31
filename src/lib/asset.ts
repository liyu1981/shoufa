export interface Asset {
  id: string
  type: "text" | "image" | "file"
  content?: string
  data?: string
  mimeType?: string
  fileName?: string
  size?: number
  ttl: number
  createdAt: number
  expiresAt: number
}
