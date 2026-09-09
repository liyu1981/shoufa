import { NextRequest, NextResponse } from "next/server"
import { deleteAsset } from "@/lib/store"

// Force dynamic for this route
export const dynamic = "force-dynamic"

// DELETE /api/[slug]/assets/[id] — delete a single asset
export async function DELETE(
  _req: NextRequest,
  { params }: { params: Promise<{ slug: string; id: string }> }
) {
  try {
    const { slug, id } = await params
    const deleted = await deleteAsset(slug, id)

    if (!deleted) {
      return NextResponse.json(
        { ok: false, error: "Asset not found" },
        { status: 404 }
      )
    }

    return NextResponse.json({ ok: true })
  } catch (error) {
    console.error("DELETE /api/[slug]/assets/[id] error:", error)
    return NextResponse.json(
      { ok: false, error: "Failed to delete asset" },
      { status: 500 }
    )
  }
}
