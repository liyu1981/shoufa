"use client"

import { useEffect, useState } from "react"
import { cn } from "@/lib/utils"

interface CountdownTimerProps {
  expiresAt: number
}

export function CountdownTimer({ expiresAt }: CountdownTimerProps) {
  const [remaining, setRemaining] = useState(0)

  useEffect(() => {
    const update = () => {
      const ms = Math.max(0, expiresAt - Date.now())
      setRemaining(ms)
    }
    update()
    const interval = setInterval(update, 1000)
    return () => clearInterval(interval)
  }, [expiresAt])

  const seconds = Math.floor(remaining / 1000)
  const minutes = Math.floor(seconds / 60)
  const hours = Math.floor(minutes / 60)

  let display: string
  if (hours > 0) {
    display = `${hours}h ${minutes % 60}m`
  } else if (minutes > 0) {
    display = `${minutes}m ${seconds % 60}s`
  } else {
    display = `${seconds}s`
  }

  const isUrgent = seconds < 30
  const isCritical = seconds < 10

  return (
    <span
      className={cn(
        "text-xs font-mono tabular-nums transition-colors duration-300",
        isCritical && "text-destructive animate-pulse",
        isUrgent && !isCritical && "text-orange-500",
        !isUrgent && "text-muted-foreground"
      )}
    >
      {display}
    </span>
  )
}
