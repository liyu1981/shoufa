"use client"

import { cn } from "@/lib/utils"
import { type ReactNode } from "react"

interface GlassCardProps {
  children: ReactNode
  className?: string
  hover?: boolean
}

export function GlassCard({ children, className, hover = false }: GlassCardProps) {
  return (
    <div
      className={cn(
        "glass-control rounded-xl p-6",
        hover && "transition-all duration-200 hover:brightness-[1.04] hover:-translate-y-px active:scale-[0.98]",
        className
      )}
    >
      {children}
    </div>
  )
}
