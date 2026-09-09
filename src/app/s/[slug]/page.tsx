"use client"

import { useCallback, useEffect, useState } from "react"
import { useRouter, useParams } from "next/navigation"
import { useTranslation } from "react-i18next"
import AmbientBackground from "@/components/AmbientBackground"
import { GlassCard } from "@/components/GlassCard"
import { PasteZone } from "@/components/PasteZone"
import { AssetCard } from "@/components/AssetCard"
import { ThemeToggle } from "@/components/ThemeToggle"
import type { Asset } from "@/lib/atoms"
import {
  Copy,
  Check,
  ArrowLeft,
  Trash2,
  Timer,
  RefreshCw,
  Link2,
  AlertTriangle,
} from "lucide-react"
import { cn } from "@/lib/utils"

interface SpaceStatus {
  exists: boolean
  disappearing: boolean
  disappearAt: number | null
  assetsCount: number
}

export default function SlugSpacePage() {
  const router = useRouter()
  const params = useParams()
  const { t } = useTranslation()
  const slug = params.slug as string

  const [assets, setAssets] = useState<Asset[]>([])
  const [loading, setLoading] = useState(true)
  const [copied, setCopied] = useState(false)
  const [clearing, setClearing] = useState(false)
  const [notFound, setNotFound] = useState(false)
  const [ttl, setTtl] = useState(300) // default 5 minutes
  const [spaceStatus, setSpaceStatus] = useState<SpaceStatus | null>(null)
  const [remainingTime, setRemainingTime] = useState<number>(0)

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

  // Fetch space status
  const fetchStatus = useCallback(async () => {
    try {
      const res = await fetch(`/api/${slug}/status`)
      const data = await res.json()
      if (data.ok) {
        setSpaceStatus(data.data)
      }
    } catch {
      // Ignore errors
    }
  }, [slug])

  // Initial fetch + polling
  useEffect(() => {
    fetchAssets()
    fetchStatus()
    const interval = setInterval(() => {
      fetchAssets()
      fetchStatus()
    }, 2000)
    return () => clearInterval(interval)
  }, [fetchAssets, fetchStatus])

  // Update remaining time for disappearing countdown
  useEffect(() => {
    if (!spaceStatus?.disappearing || !spaceStatus.disappearAt) {
      setRemainingTime(0)
      return
    }

    const updateRemaining = () => {
      const now = Date.now()
      const remaining = Math.max(0, spaceStatus.disappearAt! - now)
      setRemainingTime(remaining)

      if (remaining <= 0) {
        // Space has disappeared, go home
        router.push("/")
      }
    }

    updateRemaining()
    const interval = setInterval(updateRemaining, 1000)
    return () => clearInterval(interval)
  }, [spaceStatus, router])

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
      fetchStatus() // Refresh status after clearing
    } finally {
      setClearing(false)
    }
  }, [slug, assets, fetchStatus])

  // Asset deleted
  const handleAssetDeleted = useCallback((id: string) => {
    setAssets((prev) => prev.filter((a) => a.id !== id))
    fetchStatus() // Refresh status after deleting
  }, [fetchStatus])

  // Asset added (refetch)
  const handleAssetAdded = useCallback(() => {
    fetchAssets()
    fetchStatus()
  }, [fetchAssets, fetchStatus])

  // Format remaining time
  const formatRemaining = (ms: number): string => {
    const seconds = Math.floor(ms / 1000)
    const minutes = Math.floor(seconds / 60)
    const secs = seconds % 60
    return `${minutes}:${secs.toString().padStart(2, "0")}`
  }

  // Not found
  if (notFound) {
    return (
      <div className="ambient-bg min-h-screen w-full overflow-x-clip">
        <AmbientBackground />
        <main className="relative z-10 min-h-screen flex flex-col items-center justify-center px-4">
          <GlassCard className="text-center space-y-4">
            <p className="text-lg font-medium">{t("space.notFound")}</p>
            <p className="text-sm text-muted-foreground">
              {t("space.notFoundDesc", { slug })}
            </p>
            <button
              onClick={() => router.push("/")}
              className="px-4 py-2 rounded-xl glass-control hover:brightness-[1.06] transition-all"
            >
              {t("space.goHome")}
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
              title={t("space.goHome")}
            >
              <ArrowLeft className="w-4 h-4" />
            </button>
            <h1 className="text-sm font-semibold tracking-tight truncate max-w-[200px]">
              {slug}
            </h1>
          </div>

          <div className="flex items-center gap-1">
            <ThemeToggle className="mr-1" />

            <button
              onClick={handleCopyLink}
              className="p-2 rounded-lg hover:bg-foreground/5 transition-all flex items-center gap-1.5"
              title={t("space.copyLink")}
            >
              {copied ? (
                <Check className="w-4 h-4 text-success" />
              ) : (
                <Link2 className="w-4 h-4" />
              )}
              <span className="text-xs text-muted-foreground hidden sm:inline">
                {copied ? t("space.copied") : t("space.copyLink")}
              </span>
            </button>

            <button
              onClick={() => { fetchAssets(); fetchStatus(); }}
              className="p-2 rounded-lg hover:bg-foreground/5 transition-all"
              title={t("space.refresh")}
            >
              <RefreshCw className="w-4 h-4" />
            </button>

            {assets.length > 0 && (
              <button
                onClick={handleClearAll}
                disabled={clearing}
                className="p-2 rounded-lg hover:bg-destructive/10 hover:text-destructive transition-all"
                title={t("space.clearAll")}
              >
                <Trash2 className="w-4 h-4" />
              </button>
            )}
          </div>
        </div>
      </header>

      {/* Main content */}
      <main className="relative z-10 pt-20 pb-8 px-4 max-w-2xl mx-auto">
        {/* Disappearing warning banner */}
        {spaceStatus?.disappearing && remainingTime > 0 && (
          <div className={cn(
            "mb-4 p-4 rounded-xl border transition-all",
            "bg-orange-500/10 border-orange-500/30",
            remainingTime < 60 && "bg-destructive/10 border-destructive/30 animate-pulse"
          )}>
            <div className="flex items-center gap-3">
              <AlertTriangle className={cn(
                "w-5 h-5 shrink-0",
                remainingTime < 60 ? "text-destructive" : "text-orange-500"
              )} />
              <div className="flex-1">
                <p className="text-sm font-medium">
                  {remainingTime < 60
                    ? "Space will disappear soon!"
                    : "Space is empty and will disappear"}
                </p>
                <p className="text-xs text-muted-foreground mt-0.5">
                  Paste something to keep it alive, or it will be deleted in{" "}
                  <span className={cn(
                    "font-mono font-bold",
                    remainingTime < 60 ? "text-destructive" : "text-orange-500"
                  )}>
                    {formatRemaining(remainingTime)}
                  </span>
                </p>
              </div>
            </div>
          </div>
        )}

        {/* TTL selector */}
        <div className="flex items-center gap-2 mb-4">
          <Timer className="w-4 h-4 text-muted-foreground" />
          <span className="text-xs text-muted-foreground">{t("space.expiresIn")}:</span>
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
          ) : assets.length === 0 && !spaceStatus?.disappearing ? (
            <div className="text-center py-12">
              <p className="text-sm text-muted-foreground">
                {t("space.empty")}
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
            {t("space.assets", { count: assets.length })} · {t("space.refreshing")}
          </p>
        )}

        {/* Footer */}
        <footer className="mt-12 text-center">
          <p className="text-xs text-muted-foreground/40">
            Made with ❤️ in Sydney ·{' '}
            <a
              href="https://github.com/your-username/shoufa"
              target="_blank"
              rel="noopener noreferrer"
              className="underline hover:text-foreground/60 transition-colors"
            >
              GitHub
            </a>
          </p>
        </footer>
      </main>
    </div>
  )
}
