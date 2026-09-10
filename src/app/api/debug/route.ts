import { NextResponse } from "next/server"

export const dynamic = "force-dynamic"

export async function GET() {
  return NextResponse.json({
    redisUrl: process.env.UPSTASH_REDIS_REST_URL ? "SET" : "NOT SET",
    redisToken: process.env.UPSTASH_REDIS_REST_TOKEN ? "SET" : "NOT SET",
    redisUrlLength: process.env.UPSTASH_REDIS_REST_URL?.length || 0,
    redisTokenLength: process.env.UPSTASH_REDIS_REST_TOKEN?.length || 0,
  })
}
