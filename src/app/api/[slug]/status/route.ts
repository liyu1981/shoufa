import { NextRequest, NextResponse } from "next/server"
import { getSpaceStatus } from "@/lib/store"

// Force dynamic for this route
export const dynamic = "force-dynamic"

// GET /api/[slug]/status — get space status including disappear countdown
export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ slug: string }> }
) {
  try {
    const { slug } = await params
    const status = await getSpaceStatus(slug)
    return NextResponse.json({ ok: true, data: status })
  } catch (error) {
    console.error("GET /api/[slug]/status error:", error)
    return NextResponse.json(
      { ok: false, error: "Failed to get status" },
      { status: 500 }
    )
  }
}
