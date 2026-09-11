"use client"

import { atom } from "jotai"

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

// Current slug
export const slugAtom = atom<string>("")

// Assets in current slug
export const assetsAtom = atom<Asset[]>([])

// Loading state
export const loadingAtom = atom<boolean>(false)

// Error toast message
export const errorAtom = atom<string | null>(null)
