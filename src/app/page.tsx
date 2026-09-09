"use client"

import { useState, useCallback } from "react"
import { useRouter } from "next/navigation"
import AmbientBackground from "@/components/AmbientBackground"
import { GlassCard } from "@/components/GlassCard"
import { Zap, Link2, ArrowRight, Loader2 } from "lucide-react"

export default function HomePage() {
  const router = useRouter()
  const [customSlug, setCustomSlug] = useState("")
  const [joining, setJoining] = useState(false)
  const [creating, setCreating] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Join existing slug
  const handleJoin = useCallback(async () => {
    const slug = customSlug.trim().toLowerCase()
    if (!slug) return

    setJoining(true)
    setError(null)
    try {
      const res = await fetch(`/api/${slug}/assets`)
      const data = await res.json()
      if (data.ok) {
        router.push(`/s/${slug}`)
      } else {
        setError("Space not found. Create a new one?")
      }
    } catch {
      setError("Failed to check space")
    } finally {
      setJoining(false)
    }
  }, [customSlug, router])

  // Create new slug
  const handleCreate = useCallback(async () => {
    setCreating(true)
    setError(null)
    try {
      const res = await fetch("/api/slugs", { method: "POST" })
      const data = await res.json()
      if (data.ok) {
        router.push(`/s/${data.data.slug}`)
      } else {
        setError(data.error || "Failed to create space")
      }
    } catch {
      setError("Failed to create space")
    } finally {
      setCreating(false)
    }
  }, [router])

  // Create custom slug
  const handleCreateCustom = useCallback(async () => {
    const slug = customSlug.trim().toLowerCase()
    if (!slug) return

    setCreating(true)
    setError(null)
    try {
      const res = await fetch("/api/slugs", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ slug }),
      })
      const data = await res.json()
      if (data.ok) {
        router.push(`/s/${slug}`)
      } else {
        setError(data.error || "Failed to create space")
      }
    } catch {
      setError("Failed to create space")
    } finally {
      setCreating(false)
    }
  }, [customSlug, router])

  // Handle Enter key
  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter") {
      e.preventDefault()
      if (customSlug.trim()) {
        handleJoin()
      }
    }
  }

  return (
    <div className="ambient-bg min-h-screen w-full overflow-x-clip">
      <AmbientBackground />

      <main className="relative z-10 min-h-screen flex flex-col items-center justify-center px-4 py-12">
        {/* Logo / Title */}
        <div className="text-center mb-10">
          <h1 className="text-5xl font-bold tracking-tight text-foreground mb-3">
            Shoufa
          </h1>
          <p className="text-lg text-muted-foreground max-w-md mx-auto">
            Paste. Share. Disappear.
          </p>
          <p className="text-sm text-muted-foreground/70 mt-1">
            Ephemeral clipboard with a time limit
          </p>
        </div>

        {/* Main card */}
        <GlassCard className="w-full max-w-md space-y-6">
          {/* Join existing */}
          <div className="space-y-3">
            <label className="text-sm font-medium text-foreground/80 flex items-center gap-2">
              <Link2 className="w-4 h-4" />
              Join a space
            </label>
            <div className="flex gap-2">
              <input
                type="text"
                value={customSlug}
                onChange={(e) => {
                  setCustomSlug(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ""))
                  setError(null)
                }}
                onKeyDown={handleKeyDown}
                placeholder="Enter slug (e.g. warm-fox)"
                className="flex-1 px-4 py-2.5 rounded-xl bg-foreground/5 border border-border/50
                           text-foreground placeholder:text-muted-foreground/50
                           focus:outline-none focus:ring-2 focus:ring-ring/50
                           transition-all duration-200"
              />
              <button
                onClick={handleJoin}
                disabled={joining || !customSlug.trim()}
                className="px-4 py-2.5 rounded-xl bg-primary text-primary-foreground
                           hover:brightness-110 active:scale-95
                           disabled:opacity-40 disabled:cursor-not-allowed
                           transition-all duration-150 flex items-center gap-2"
              >
                {joining ? (
                  <Loader2 className="w-4 h-4 animate-spin" />
                ) : (
                  <ArrowRight className="w-4 h-4" />
                )}
              </button>
            </div>
          </div>

          {/* Divider */}
          <div className="relative">
            <div className="absolute inset-0 flex items-center">
              <div className="w-full border-t border-border/30" />
            </div>
            <div className="relative flex justify-center text-xs">
              <span className="bg-card px-3 text-muted-foreground">or</span>
            </div>
          </div>

          {/* Create new */}
          <div className="space-y-3">
            <label className="text-sm font-medium text-foreground/80 flex items-center gap-2">
              <Zap className="w-4 h-4" />
              Create a space
            </label>

            <div className="flex gap-2">
              <input
                type="text"
                value={customSlug}
                onChange={(e) => {
                  setCustomSlug(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ""))
                  setError(null)
                }}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault()
                    if (customSlug.trim()) {
                      handleCreateCustom()
                    } else {
                      handleCreate()
                    }
                  }
                }}
                placeholder="slug"
                className="flex-1 px-4 py-2.5 rounded-xl bg-foreground/5 border border-border/50
                           text-foreground placeholder:text-muted-foreground/50
                           focus:outline-none focus:ring-2 focus:ring-ring/50
                           transition-all duration-200"
              />
              <button
                onClick={customSlug.trim() ? handleCreateCustom : handleCreate}
                disabled={creating}
                className="px-4 py-2.5 rounded-xl glass-control text-foreground/90
                           hover:brightness-[1.06] active:scale-95
                           disabled:opacity-40 disabled:cursor-not-allowed
                           transition-all duration-150 flex items-center gap-2"
              >
                {creating ? (
                  <Loader2 className="w-4 h-4 animate-spin" />
                ) : (
                  <>
                    <Zap className="w-4 h-4" />
                    generate
                  </>
                )}
              </button>
            </div>
          </div>

          {/* Error */}
          {error && (
            <p className="text-sm text-destructive text-center">{error}</p>
          )}
        </GlassCard>

        {/* Footer */}
        <p className="text-xs text-muted-foreground/50 mt-8 text-center">
          Content auto-expires after 5 minutes · No accounts needed
        </p>
      </main>
    </div>
  )
}
