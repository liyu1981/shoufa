import { NextRequest, NextResponse } from "next/server"
import { deleteSlug, getSlug } from "@/lib/store"

// Force dynamic for this route
export const dynamic = "force-dynamic"

// DELETE /api/[slug] — destroy entire slug and all its assets
export async function DELETE(
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

    await deleteSlug(slug)
    return NextResponse.json({ ok: true })
  } catch (error) {
    console.error("DELETE /api/[slug] error:", error)
    return NextResponse.json(
      { ok: false, error: "Failed to delete space" },
      { status: 500 }
    )
  }
}
