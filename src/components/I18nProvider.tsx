"use client"

import { useEffect, type ReactNode } from "react"
import "@/i18n/config"

export function I18nProvider({ children }: { children: ReactNode }) {
  useEffect(() => {
    // i18n is initialized on import
  }, [])

  return <>{children}</>
}
