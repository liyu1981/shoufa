"use client"

import { useState, useCallback, useRef, useEffect } from "react"
import { useRouter } from "next/navigation"
import { useTranslation } from "react-i18next"
import AmbientBackground from "@/components/AmbientBackground"
import { GlassCard } from "@/components/GlassCard"
import { ThemeToggle } from "@/components/ThemeToggle"
import { useRecentSlugs } from "@/hooks/use-recent-slugs"
import { Zap, Link2, ArrowRight, Loader2, Clock, X } from "lucide-react"

export default function HomePage() {
  const router = useRouter()
  const { t } = useTranslation()
  const { recentSlugs, addSlug, removeSlug } = useRecentSlugs()
  const [customSlug, setCustomSlug] = useState("")
  const [joining, setJoining] = useState(false)
  const [creating, setCreating] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [showDropdown, setShowDropdown] = useState(false)
  const dropdownRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)

  // Close dropdown when clicking outside
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
        setShowDropdown(false)
      }
    }
    document.addEventListener("mousedown", handleClickOutside)
    return () => document.removeEventListener("mousedown", handleClickOutside)
  }, [])

  // Join existing slug
  const handleJoin = useCallback(async (slugToJoin?: string) => {
    const slug = (slugToJoin || customSlug).trim().toLowerCase()
    if (!slug) return

    setJoining(true)
    setError(null)
    try {
      const res = await fetch(`/api/${slug}/assets`)
      const data = await res.json()
      if (data.ok) {
        addSlug(slug)
        router.push(`/s/${slug}`)
      } else {
        setError("Space not found. Create a new one?")
      }
    } catch {
      setError("Failed to check space")
    } finally {
      setJoining(false)
    }
  }, [customSlug, router, addSlug])

  // Create new slug
  const handleCreate = useCallback(async () => {
    setCreating(true)
    setError(null)
    try {
      const res = await fetch("/api/slugs", { method: "POST" })
      const data = await res.json()
      if (data.ok) {
        addSlug(data.data.slug)
        router.push(`/s/${data.data.slug}`)
      } else {
        setError(data.error || "Failed to create space")
      }
    } catch {
      setError("Failed to create space")
    } finally {
      setCreating(false)
    }
  }, [router, addSlug])

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
        addSlug(slug)
        router.push(`/s/${slug}`)
      } else {
        setError(data.error || "Failed to create space")
      }
    } catch {
      setError("Failed to create space")
    } finally {
      setCreating(false)
    }
  }, [customSlug, router, addSlug])

  // Handle Enter key
  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter") {
      e.preventDefault()
      if (customSlug.trim()) {
        handleJoin()
      }
    }
  }

  // Select from recent
  const handleSelectRecent = (slug: string) => {
    setCustomSlug(slug)
    setShowDropdown(false)
    handleJoin(slug)
  }

  // Remove from recent
  const handleRemoveRecent = (e: React.MouseEvent, slug: string) => {
    e.stopPropagation()
    removeSlug(slug)
  }

  // Filter recent slugs based on input
  const filteredRecent = customSlug.trim()
    ? recentSlugs.filter((s) => s.includes(customSlug.trim().toLowerCase()))
    : recentSlugs

  // JSON-LD structured data for search engines
  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "WebApplication",
    name: "Shoufa",
    alternateName: "Shoufa — Paste, Share, Disappear",
    url: process.env.NEXT_PUBLIC_SITE_URL || "https://shoufa.vercel.app",
    applicationCategory: "UtilitiesApplication",
    operatingSystem: "Any",
    description:
      "Ephemeral clipboard with a time limit. Paste text or images, share a memorable link, and it auto-expires. No signup needed.",
    offers: {
      "@type": "Offer",
      price: "0",
      priceCurrency: "USD",
    },
    featureList: [
      "Paste text with auto-expiry",
      "Upload images with self-destructing links",
      "Memorable shareable links like bright-fox",
      "No signup or account required",
      "Works on mobile and desktop",
    ],
  }

  return (
    <div className="ambient-bg min-h-screen w-full overflow-x-clip">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      <AmbientBackground />

      <main className="relative z-10 min-h-screen flex flex-col items-center justify-center px-4 py-12">
        {/* Logo / Title */}
        <div className="text-center mb-10">
          <h1 className="text-5xl font-bold tracking-tight text-foreground mb-3">
            {t("app.title")}
          </h1>
          <p className="text-lg text-muted-foreground max-w-md mx-auto">
            {t("app.tagline")}
          </p>
          <p className="text-sm text-muted-foreground/70 mt-1">
            {t("app.description")}
          </p>
        </div>

        {/* Theme & Language toggle */}
        <div className="absolute top-4 right-4">
          <ThemeToggle />
        </div>

        {/* Main card */}
        <GlassCard className="w-full max-w-md space-y-6">
          {/* Join existing */}
          <div className="space-y-3">
            <label className="text-sm font-medium text-foreground/80 flex items-center gap-2">
              <Link2 className="w-4 h-4" />
              {t("home.join.label")}
            </label>
            <div className="relative flex gap-2" ref={dropdownRef}>
              <div className="relative flex-1">
                <input
                  ref={inputRef}
                  type="text"
                  value={customSlug}
                  onChange={(e) => {
                    setCustomSlug(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ""))
                    setError(null)
                    setShowDropdown(true)
                  }}
                  onFocus={() => setShowDropdown(true)}
                  onKeyDown={handleKeyDown}
                  placeholder={t("home.join.placeholder")}
                  className="w-full px-4 py-2.5 rounded-xl bg-foreground/5 border border-border/50
                             text-foreground placeholder:text-muted-foreground/50
                             focus:outline-none focus:ring-2 focus:ring-ring/50
                             transition-all duration-200"
                />

                {/* Recent slugs dropdown */}
                {showDropdown && filteredRecent.length > 0 && (
                  <div className="absolute top-full left-0 right-0 mt-1 py-1 bg-card border border-border/50 rounded-xl shadow-lg z-50 max-h-48 overflow-y-auto">
                    <div className="px-3 py-1.5 text-xs text-muted-foreground flex items-center gap-1.5">
                      <Clock className="w-3 h-3" />
                      Recent
                    </div>
                    {filteredRecent.map((slug) => (
                      <div
                        key={slug}
                        onClick={() => handleSelectRecent(slug)}
                        className="w-full px-3 py-2 text-left text-sm hover:bg-foreground/5 flex items-center justify-between group transition-colors cursor-pointer"
                      >
                        <span className="font-mono text-foreground/80">{slug}</span>
                        <span
                          onClick={(e) => handleRemoveRecent(e, slug)}
                          className="p-1 rounded hover:bg-destructive/10 hover:text-destructive opacity-0 group-hover:opacity-100 transition-all cursor-pointer"
                        >
                          <X className="w-3 h-3" />
                        </span>
                      </div>
                    ))}
                  </div>
                )}
              </div>

              <button
                onClick={() => handleJoin()}
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
              {t("home.create.label")}
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
                placeholder={t("home.create.placeholder")}
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
                    {t("home.create.generate")}
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
        <footer className="mt-12 text-center space-y-2">
          <p className="text-xs text-muted-foreground/50">
            {t("home.footer")}
          </p>
          <p className="text-xs text-muted-foreground/40">
            Made with ❤️ in Sydney ·{' '}
            <a
              href="https://github.com/liyu1981/shoufa"
              target="_blank"
              rel="noopener noreferrer"
              className="underline hover:text-foreground/60 transition-colors"
            >
              GitHub
            </a>
          </p>
        </footer>

        {/* How it works */}
        <section className="mt-12 max-w-lg mx-auto px-4">
          <div className="flex items-center justify-center gap-4 text-sm text-muted-foreground/70">
            <div className="flex items-center gap-2">
              <span className="w-6 h-6 rounded-full bg-foreground/5 flex items-center justify-center text-xs font-medium">1</span>
              <span>Create</span>
            </div>
            <span className="text-border">→</span>
            <div className="flex items-center gap-2">
              <span className="w-6 h-6 rounded-full bg-foreground/5 flex items-center justify-center text-xs font-medium">2</span>
              <span>Paste</span>
            </div>
            <span className="text-border">→</span>
            <div className="flex items-center gap-2">
              <span className="w-6 h-6 rounded-full bg-foreground/5 flex items-center justify-center text-xs font-medium">3</span>
              <span>Share</span>
            </div>
          </div>
        </section>
      </main>
    </div>
  )
}
