"use client"

import { useEffect, useCallback } from "react"
import { cn } from "@/lib/utils"
import { X, AlertTriangle } from "lucide-react"

interface AlertDialogProps {
  open: boolean
  onClose: () => void
  title?: string
  message: string
}

export function AlertDialog({ open, onClose, title = "Error", message }: AlertDialogProps) {
  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (e.key === "Escape" || e.key === "Enter") {
        onClose()
      }
    },
    [onClose]
  )

  useEffect(() => {
    if (open) {
      document.addEventListener("keydown", handleKeyDown)
      return () => document.removeEventListener("keydown", handleKeyDown)
    }
  }, [open, handleKeyDown])

  if (!open) return null

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-black/50 backdrop-blur-sm"
        onClick={onClose}
      />

      {/* Dialog */}
      <div
        className={cn(
          "relative z-10 w-full max-w-sm mx-4",
          "bg-card border border-border/50 rounded-2xl shadow-xl",
          "p-6 space-y-4",
          "animate-in fade-in zoom-in-95 duration-200"
        )}
      >
        {/* Header */}
        <div className="flex items-center gap-3">
          <div className="p-2 rounded-xl bg-destructive/10">
            <AlertTriangle className="w-5 h-5 text-destructive" />
          </div>
          <h3 className="text-lg font-semibold text-foreground">{title}</h3>
        </div>

        {/* Message */}
        <p className="text-sm text-muted-foreground">{message}</p>

        {/* Close button */}
        <button
          onClick={onClose}
          className={cn(
            "w-full px-4 py-2.5 rounded-xl",
            "bg-foreground/5 hover:bg-foreground/10",
            "text-sm font-medium text-foreground",
            "transition-all duration-150",
            "active:scale-[0.98]"
          )}
        >
          OK
        </button>
      </div>
    </div>
  )
}
