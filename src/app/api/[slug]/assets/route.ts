import { NextRequest, NextResponse } from "next/server"
import { getSlug, getAssets, addAsset } from "@/lib/store"
import { limits } from "@/lib/config"

// Force dynamic for this route
export const dynamic = "force-dynamic"

// Safety margin: reject at 90% of limit
const SAFETY_MARGIN = 0.9

// GET /api/[slug]/assets — list all non-expired assets
export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ slug: string }> }
) {
  try {
    const { slug } = await params
    const space = await getSlug(slug)

    if (!space) {
      return NextResponse.json(
        { ok: false, error: "Space not found" },
        { status: 404 }
      )
    }

    const assets = await getAssets(slug)
    return NextResponse.json({ ok: true, data: assets })
  } catch (error) {
    console.error("GET /api/[slug]/assets error:", error)
    return NextResponse.json(
      { ok: false, error: "Failed to fetch assets" },
      { status: 500 }
    )
  }
}

// POST /api/[slug]/assets — add a new asset (text or image)
export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ slug: string }> }
) {
  try {
    const { slug } = await params
    const config = limits()
    const maxRequestSize = config.requestSize * SAFETY_MARGIN

    const space = await getSlug(slug)

    if (!space) {
      return NextResponse.json(
        { ok: false, error: "Space not found" },
        { status: 404 }
      )
    }

    // Check content-length header if available (best effort)
    const contentLength = req.headers.get("content-length")
    if (contentLength) {
      const size = parseInt(contentLength, 10)
      if (size > maxRequestSize) {
        return NextResponse.json(
          {
            ok: false,
            error: `Request too large (${formatBytes(size)}). Maximum is ${formatBytes(maxRequestSize)}.`,
          },
          { status: 413 }
        )
      }
    }

    const contentType = req.headers.get("content-type") || ""

    if (contentType.includes("application/json")) {
      // Text asset
      const body = await req.json()
      const text = body.content as string

      // Validate TTL
      const ttl = Math.min(Math.max(Number(body.ttl) || 300, 10), config.maxTtl)

      if (!text || text.trim().length === 0) {
        return NextResponse.json(
          { ok: false, error: "Content cannot be empty" },
          { status: 400 }
        )
      }

      // Check text size (approximate)
      const textSize = new TextEncoder().encode(text).length
      if (textSize > maxRequestSize) {
        return NextResponse.json(
          {
            ok: false,
            error: `Text too large (${formatBytes(textSize)}). Maximum is ${formatBytes(maxRequestSize)}.`,
          },
          { status: 413 }
        )
      }

      const asset = await addAsset(slug, {
        type: "text",
        content: text,
        ttl,
      })

      if (!asset) {
        return NextResponse.json(
          { ok: false, error: "Failed to save asset" },
          { status: 500 }
        )
      }

      return NextResponse.json({ ok: true, data: asset })
    } else if (contentType.includes("multipart/form-data")) {
      // File asset (image or any other file)
      const formData = await req.formData()
      const file = formData.get("file") as File | null
      const ttl = Math.min(Math.max(Number(formData.get("ttl")) || 300, 10), config.maxTtl)

      if (!file) {
        return NextResponse.json(
          { ok: false, error: "No file provided" },
          { status: 400 }
        )
      }

      // Determine asset type based on MIME type
      const isImage = file.type.startsWith("image/")
      const assetType = isImage ? "image" : "file"

      // Check file size BEFORE base64 conversion
      const maxFileSize = config.maxImageSize * SAFETY_MARGIN
      if (file.size > maxFileSize) {
        return NextResponse.json(
          {
            ok: false,
            error: `File too large (${formatBytes(file.size)}). Maximum is ${formatBytes(maxFileSize)}.`,
          },
          { status: 413 }
        )
      }

      // Convert to base64 data URL
      const bytes = await file.arrayBuffer()
      const base64 = Buffer.from(bytes).toString("base64")
      const dataUrl = `data:${file.type};base64,${base64}`

      // Double-check base64 size (it's ~33% larger than original)
      if (dataUrl.length > maxRequestSize) {
        return NextResponse.json(
          {
            ok: false,
            error: `File too large after encoding (${formatBytes(dataUrl.length)}). Maximum is ${formatBytes(maxRequestSize)}.`,
          },
          { status: 413 }
        )
      }

      const asset = await addAsset(slug, {
        type: assetType,
        data: dataUrl,
        mimeType: file.type,
        fileName: file.name,
        size: file.size,
        ttl,
      })

      if (!asset) {
        return NextResponse.json(
          { ok: false, error: "Failed to save file" },
          { status: 500 }
        )
      }

      return NextResponse.json({ ok: true, data: asset })
    } else {
      return NextResponse.json(
        { ok: false, error: "Unsupported content type" },
        { status: 415 }
      )
    }
  } catch (error) {
    console.error("POST /api/[slug]/assets error:", error)
    return NextResponse.json(
      { ok: false, error: "Failed to add asset" },
      { status: 500 }
    )
  }
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`
}
