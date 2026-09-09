"use client"

import { useCallback, useEffect, useState } from "react"
import { useRouter, useParams } from "next/navigation"
import AmbientBackground from "@/components/AmbientBackground"
import { GlassCard } from "@/components/GlassCard"
import { PasteZone } from "@/components/PasteZone"
import { AssetCard } from "@/components/AssetCard"
import type { Asset } from "@/lib/atoms"
import {
  Copy,
  Check,
  ArrowLeft,
  Trash2,
  Timer,
  RefreshCw,
  Link2,
} from "lucide-react"

export default function SlugSpacePage() {
  const router = useRouter()
  const params = useParams()
  const slug = params.slug as string

  const [assets, setAssets] = useState<Asset[]>([])
  const [loading, setLoading] = useState(true)
  const [copied, setCopied] = useState(false)
  const [clearing, setClearing] = useState(false)
  const [notFound, setNotFound] = useState(false)
  const [ttl, setTtl] = useState(300) // default 5 minutes

  // Fetch assets
  const fetchAssets = useCallback(async () => {
    try {
      const res = await fetch(`/api/${slug}/assets`)
      const data = await res.json()
      if (data.ok) {
        setAssets(data.data)
        setNotFound(false)
      } else {
        setNotFound(true)
      }
    } catch {
      setNotFound(true)
    } finally {
      setLoading(false)
    }
  }, [slug])

  // Initial fetch + polling
  useEffect(() => {
    fetchAssets()
    const interval = setInterval(fetchAssets, 2000)
    return () => clearInterval(interval)
  }, [fetchAssets])

  // Copy link
  const handleCopyLink = useCallback(async () => {
    const url = `${window.location.origin}/s/${slug}`
    await navigator.clipboard.writeText(url)
    setCopied(true)
    setTimeout(() => setCopied(false), 1500)
  }, [slug])

  // Clear all assets
  const handleClearAll = useCallback(async () => {
    setClearing(true)
    try {
      for (const asset of assets) {
        await fetch(`/api/${slug}/assets/${asset.id}`, { method: "DELETE" })
      }
      setAssets([])
    } finally {
      setClearing(false)
    }
  }, [slug, assets])

  // Asset deleted
  const handleAssetDeleted = useCallback((id: string) => {
    setAssets((prev) => prev.filter((a) => a.id !== id))
  }, [])

  // Asset added (refetch)
  const handleAssetAdded = useCallback(() => {
    fetchAssets()
  }, [fetchAssets])

  // Not found
  if (notFound) {
    return (
      <div className="ambient-bg min-h-screen w-full overflow-x-clip">
        <AmbientBackground />
        <main className="relative z-10 min-h-screen flex flex-col items-center justify-center px-4">
          <GlassCard className="text-center space-y-4">
            <p className="text-lg font-medium">Space not found</p>
            <p className="text-sm text-muted-foreground">
              &quot;{slug}&quot; doesn&apos;t exist or has expired.
            </p>
            <button
              onClick={() => router.push("/")}
              className="px-4 py-2 rounded-xl glass-control hover:brightness-[1.06] transition-all"
            >
              Go home
            </button>
          </GlassCard>
        </main>
      </div>
    )
  }

  return (
    <div className="ambient-bg min-h-screen w-full overflow-x-clip">
      <AmbientBackground />

      {/* Sticky header */}
      <header className="fixed top-0 left-0 right-0 z-20 apple-panel">
        <div className="max-w-2xl mx-auto px-4 h-14 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <button
              onClick={() => router.push("/")}
              className="p-2 rounded-lg hover:bg-foreground/5 transition-all"
              title="Go home"
            >
              <ArrowLeft className="w-4 h-4" />
            </button>
            <h1 className="text-sm font-semibold tracking-tight truncate max-w-[200px]">
              {slug}
            </h1>
          </div>

          <div className="flex items-center gap-1">
            <button
              onClick={handleCopyLink}
              className="p-2 rounded-lg hover:bg-foreground/5 transition-all flex items-center gap-1.5"
              title="Copy link"
            >
              {copied ? (
                <Check className="w-4 h-4 text-success" />
              ) : (
                <Link2 className="w-4 h-4" />
              )}
              <span className="text-xs text-muted-foreground hidden sm:inline">
                {copied ? "Copied" : "Copy link"}
              </span>
            </button>

            <button
              onClick={fetchAssets}
              className="p-2 rounded-lg hover:bg-foreground/5 transition-all"
              title="Refresh"
            >
              <RefreshCw className="w-4 h-4" />
            </button>

            {assets.length > 0 && (
              <button
                onClick={handleClearAll}
                disabled={clearing}
                className="p-2 rounded-lg hover:bg-destructive/10 hover:text-destructive transition-all"
                title="Clear all"
              >
                <Trash2 className="w-4 h-4" />
              </button>
            )}
          </div>
        </div>
      </header>

      {/* Main content */}
      <main className="relative z-10 pt-20 pb-8 px-4 max-w-2xl mx-auto">
        {/* TTL selector */}
        <div className="flex items-center gap-2 mb-4">
          <Timer className="w-4 h-4 text-muted-foreground" />
          <span className="text-xs text-muted-foreground">Expires in:</span>
          {[60, 300, 900, 3600].map((t) => (
            <button
              key={t}
              onClick={() => setTtl(t)}
              className={`px-2 py-1 rounded-lg text-xs transition-all ${
                ttl === t
                  ? "bg-primary text-primary-foreground"
                  : "bg-foreground/5 text-muted-foreground hover:bg-foreground/10"
              }`}
            >
              {t < 60 ? `${t}s` : t < 3600 ? `${t / 60}m` : `${t / 3600}h`}
            </button>
          ))}
        </div>

        {/* Paste zone */}
        <PasteZone slug={slug} onAssetAdded={handleAssetAdded} ttl={ttl} />

        {/* Assets list */}
        <div className="mt-6 space-y-3">
          {loading && assets.length === 0 ? (
            <div className="text-center py-12">
              <RefreshCw className="w-6 h-6 text-muted-foreground animate-spin mx-auto" />
            </div>
          ) : assets.length === 0 ? (
            <div className="text-center py-12">
              <p className="text-sm text-muted-foreground">
                Nothing here yet. Paste something above!
              </p>
            </div>
          ) : (
            assets.map((asset) => (
              <AssetCard
                key={asset.id}
                asset={asset}
                slug={slug}
                onDelete={handleAssetDeleted}
              />
            ))
          )}
        </div>

        {/* Footer info */}
        {assets.length > 0 && (
          <p className="text-xs text-muted-foreground/50 text-center mt-8">
            {assets.length} asset{assets.length !== 1 ? "s" : ""} · Auto-refreshing every 2s
          </p>
        )}
      </main>
    </div>
  )
}
