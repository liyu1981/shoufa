import { NextRequest, NextResponse } from "next/server"
import { slugExists } from "@/lib/store"

// Force dynamic for this route
export const dynamic = "force-dynamic"

// GET /api/[slug]/exists — check if a slug exists
export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ slug: string }> }
) {
  try {
    const { slug } = await params
    const exists = await slugExists(slug)
    return NextResponse.json({ ok: true, data: { exists } })
  } catch (error) {
    console.error("GET /api/[slug]/exists error:", error)
    return NextResponse.json(
      { ok: false, error: "Failed to check slug" },
      { status: 500 }
    )
  }
}
