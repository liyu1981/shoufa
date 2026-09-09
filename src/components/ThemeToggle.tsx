"use client"

import { useTheme } from "next-themes"
import { useTranslation } from "react-i18next"
import { useEffect, useState, useRef } from "react"
import { cn } from "@/lib/utils"
import { Sun, Moon, Monitor, Globe, Check } from "lucide-react"

export function ThemeToggle({ className }: { className?: string }) {
  const { theme, setTheme } = useTheme()
  const { i18n, t } = useTranslation()
  const [mounted, setMounted] = useState(false)
  const [themeOpen, setThemeOpen] = useState(false)
  const [langOpen, setLangOpen] = useState(false)
  const themeRef = useRef<HTMLDivElement>(null)
  const langRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    setMounted(true)
  }, [])

  // Close dropdowns on outside click
  useEffect(() => {
    const handleClick = (e: MouseEvent) => {
      if (themeRef.current && !themeRef.current.contains(e.target as Node)) {
        setThemeOpen(false)
      }
      if (langRef.current && !langRef.current.contains(e.target as Node)) {
        setLangOpen(false)
      }
    }
    document.addEventListener("mousedown", handleClick)
    return () => document.removeEventListener("mousedown", handleClick)
  }, [])

  if (!mounted) {
    return <div className={cn("w-20 h-9", className)} />
  }

  const themes = [
    { value: "light", icon: Sun, label: t("theme.light") },
    { value: "dark", icon: Moon, label: t("theme.dark") },
    { value: "system", icon: Monitor, label: t("theme.system") },
  ] as const

  const languages = [
    { code: "en", label: "English" },
    { code: "zh", label: "中文" },
  ]

  const currentLang = i18n.language?.split("-")[0] || "en"
  const CurrentThemeIcon = themes.find(t => t.value === theme)?.icon || Monitor

  return (
    <div className={cn("flex items-center gap-1", className)}>
      {/* Theme dropdown */}
      <div ref={themeRef} className="relative">
        <button
          onClick={() => {
            setThemeOpen(!themeOpen)
            setLangOpen(false)
          }}
          className="p-2 rounded-lg glass-control hover:brightness-[1.06] transition-all"
          title={t("theme.system")}
        >
          <CurrentThemeIcon className="w-4 h-4" />
        </button>

        {themeOpen && (
          <div className="absolute right-0 top-full mt-1 glass-control rounded-xl py-1 min-w-[120px] z-50">
            {themes.map(({ value, icon: Icon, label }) => (
              <button
                key={value}
                onClick={() => {
                  setTheme(value)
                  setThemeOpen(false)
                }}
                className={cn(
                  "w-full px-3 py-2 text-sm flex items-center gap-2 transition-all",
                  "hover:bg-foreground/5 text-left",
                  theme === value ? "text-foreground" : "text-muted-foreground"
                )}
              >
                <Icon className="w-4 h-4" />
                <span className="flex-1">{label}</span>
                {theme === value && <Check className="w-3.5 h-3.5 text-primary" />}
              </button>
            ))}
          </div>
        )}
      </div>

      {/* Language dropdown */}
      <div ref={langRef} className="relative">
        <button
          onClick={() => {
            setLangOpen(!langOpen)
            setThemeOpen(false)
          }}
          className="p-2 rounded-lg glass-control hover:brightness-[1.06] transition-all flex items-center gap-1"
          title="Language"
        >
          <Globe className="w-4 h-4" />
          <span className="text-xs font-medium">{currentLang.toUpperCase()}</span>
        </button>

        {langOpen && (
          <div className="absolute right-0 top-full mt-1 glass-control rounded-xl py-1 min-w-[100px] z-50">
            {languages.map(({ code, label }) => (
              <button
                key={code}
                onClick={() => {
                  i18n.changeLanguage(code)
                  setLangOpen(false)
                }}
                className={cn(
                  "w-full px-3 py-2 text-sm flex items-center gap-2 transition-all",
                  "hover:bg-foreground/5 text-left",
                  currentLang === code ? "text-foreground" : "text-muted-foreground"
                )}
              >
                <span className="flex-1">{label}</span>
                {currentLang === code && <Check className="w-3.5 h-3.5 text-primary" />}
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
