import { NextRequest, NextResponse } from "next/server"
import { getSlug, getAssets, addAsset } from "@/lib/store"

// Force dynamic for this route
export const dynamic = "force-dynamic"

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
    const space = await getSlug(slug)

    if (!space) {
      return NextResponse.json(
        { ok: false, error: "Space not found" },
        { status: 404 }
      )
    }

    const contentType = req.headers.get("content-type") || ""

    if (contentType.includes("application/json")) {
      // Text asset
      const body = await req.json()
      const text = body.content as string
      const ttl = Math.min(Math.max(Number(body.ttl) || 300, 10), 3600) // 10s to 1h, default 5min

      if (!text || text.trim().length === 0) {
        return NextResponse.json(
          { ok: false, error: "Content cannot be empty" },
          { status: 400 }
        )
      }

      const asset = await addAsset(slug, {
        type: "text",
        content: text,
        ttl,
      })

      return NextResponse.json({ ok: true, data: asset })
    } else if (contentType.includes("multipart/form-data")) {
      // Image asset
      const formData = await req.formData()
      const file = formData.get("file") as File | null
      const ttl = Math.min(Math.max(Number(formData.get("ttl")) || 300, 10), 3600)

      if (!file) {
        return NextResponse.json(
          { ok: false, error: "No file provided" },
          { status: 400 }
        )
      }

      if (!file.type.startsWith("image/")) {
        return NextResponse.json(
          { ok: false, error: "Only image files are allowed" },
          { status: 400 }
        )
      }

      // Convert to base64 data URL
      const bytes = await file.arrayBuffer()
      const base64 = Buffer.from(bytes).toString("base64")
      const dataUrl = `data:${file.type};base64,${base64}`

      const asset = await addAsset(slug, {
        type: "image",
        data: dataUrl,
        mimeType: file.type,
        fileName: file.name,
        ttl,
      })

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
