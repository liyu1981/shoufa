import { NextResponse } from "next/server"
import { limits, formatLimits } from "@/lib/config"
import { getStorageProviderInfo } from "@/lib/storage"

// GET /api/config — show current tier limits and storage backend
export async function GET() {
  const l = limits()
  const storage = getStorageProviderInfo()
  const tier =
    storage.kind === "self-hosted"
      ? "self-hosted"
      : process.env.UPSTASH_TIER || "free"

  return NextResponse.json({
    ok: true,
    data: {
      tier,
      limits: l,
      summary: `${formatLimits(tier)} | Storage: ${storage.kind}`,
      storage,
    },
  })
}
