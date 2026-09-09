import { NextResponse } from "next/server"
import { limits, formatLimits } from "@/lib/config"

// GET /api/config — show current tier limits
export async function GET() {
  const l = limits()
  return NextResponse.json({
    ok: true,
    data: {
      tier: process.env.UPSTASH_TIER || "free",
      limits: l,
      summary: formatLimits(),
    },
  })
}
