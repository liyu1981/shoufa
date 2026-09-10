import { NextRequest, NextResponse } from "next/server"
import { createSlug, slugExists, isSlugTaken } from "@/lib/store"
import { generateSlug, isValidSlug } from "@/lib/slugs"

// Force dynamic for this route
export const dynamic = "force-dynamic"

// POST /api/slugs — create a new slug
export async function POST(req: NextRequest) {
  try {
    const body = await req.json().catch(() => ({}))
    const customSlug = body.slug as string | undefined

    let slug: string

    if (customSlug) {
      // Validate custom slug
      if (!isValidSlug(customSlug)) {
        return NextResponse.json(
          { ok: false, error: "Invalid slug. Use lowercase letters, numbers, and single hyphens (2-32 chars)." },
          { status: 400 }
        )
      }
      if (await slugExists(customSlug)) {
        return NextResponse.json(
          { ok: false, error: "This slug is already taken." },
          { status: 409 }
        )
      }
      slug = customSlug
    } else {
      // Auto-generate
      slug = await generateSlug(isSlugTaken)
    }

    await createSlug(slug)

    return NextResponse.json({ ok: true, data: { slug } })
  } catch (error) {
    console.error("POST /api/slugs error:", error)
    console.error("Error details:", {
      message: error instanceof Error ? error.message : "Unknown error",
      stack: error instanceof Error ? error.stack : undefined,
      redisUrl: process.env.UPSTASH_REDIS_REST_URL ? "SET" : "NOT SET",
      redisToken: process.env.UPSTASH_REDIS_REST_TOKEN ? "SET" : "NOT SET",
    })
    return NextResponse.json(
      { ok: false, error: "Failed to create slug" },
      { status: 500 }
    )
  }
}
