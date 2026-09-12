"use client"

import { useEffect, useState, useCallback } from "react"
import { createPortal } from "react-dom"
import { useTranslation } from "react-i18next"
import { cn } from "@/lib/utils"
import { isOptimizable, optimizeImage, estimateOptionSizes, humanSize } from "@/lib/image-optimize"
import { Check, AlertTriangle, Loader2 } from "lucide-react"

interface ImageOptimizeDialogProps {
  open: boolean
  file: File | null
  maxAllowedSize: number
  onConfirm: (optimized: File) => void
  onCancel: () => void
}

/**
 * Outer shell — controls visibility. When open, renders a keyed inner
 * component so state is always fresh (no reset-in-effect needed).
 */
export function ImageOptimizeDialog(props: ImageOptimizeDialogProps) {
  if (!props.open) return null

  // Key forces a fresh mount each time the dialog opens with a new file
  const key = `${props.file?.name ?? ""}-${props.file?.size ?? 0}-${props.open}`

  return createPortal(
    <div className="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto p-4">
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-black/50 backdrop-blur-sm"
        onClick={props.onCancel}
      />
      <ImageOptimizeDialogInner key={key} {...props} />
    </div>,
    document.body,
  )
}

/* ------------------------------------------------------------------ */
/*  Inner component — owns all state, mounts fresh every time `open`  */
/* ------------------------------------------------------------------ */

function ImageOptimizeDialogInner({
  file,
  maxAllowedSize,
  onConfirm,
  onCancel,
}: Omit<ImageOptimizeDialogProps, "open">) {
  const { t } = useTranslation()
  const [selected, setSelected] = useState<string | null>("compress")
  const [optimizing, setOptimizing] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [sizes, setSizes] = useState<Record<string, number>>({})

  const options = [
    { id: "compress", label: "Compress (keep resolution)" },
    { id: "resize75", label: "Resize to 75% + compress" },
    { id: "resize50", label: "Resize to 50% + compress" },
    { id: "resize33", label: "Resize to 33% + compress" },
  ]

  // Compute estimates in background (fast, uses toDataURL)
  useEffect(() => {
    if (!file || !isOptimizable(file)) return
    let cancelled = false
    estimateOptionSizes(file).then((result) => {
      if (cancelled) return
      setSizes(result)
      // Auto-select first option under limit
      const bestId = options.find((o) => result[o.id] != null && result[o.id] <= maxAllowedSize)?.id
      if (bestId) setSelected(bestId)
    })
    return () => { cancelled = true }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [maxAllowedSize])

  const handleConfirm = useCallback(async () => {
    if (!file || !selected) return

    setOptimizing(true)
    setError(null)
    try {
      const optimized = await optimizeImage(file, selected)
      if (optimized.size > maxAllowedSize) {
        setError(t("optimize.stillTooLarge"))
        setOptimizing(false)
        return
      }
      onConfirm(optimized)
    } catch {
      setError(t("optimize.failed"))
      setOptimizing(false)
    }
  }, [file, selected, maxAllowedSize, onConfirm, t])

  // Escape to cancel
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") onCancel()
    }
    document.addEventListener("keydown", handler)
    return () => document.removeEventListener("keydown", handler)
  }, [onCancel])

  return (
    <div
      className={cn(
        "relative z-10 w-full max-w-md",
        "bg-card border border-border/50 rounded-2xl shadow-xl",
        "p-6 space-y-5",
        "animate-in fade-in zoom-in-95 duration-200",
      )}
      onClick={(e) => e.stopPropagation()}
    >
      {/* Header */}
      <div className="flex items-center gap-3">
        <div className="p-2 rounded-xl bg-orange-500/10">
          <AlertTriangle className="w-5 h-5 text-orange-500" />
        </div>
        <div>
          <h3 className="text-lg font-semibold text-foreground">
            {t("optimize.title")}
          </h3>
          <p className="text-xs text-muted-foreground">
            {t("optimize.description", {
              size: humanSize(file?.size ?? 0),
              max: humanSize(maxAllowedSize),
            })}
          </p>
        </div>
      </div>

      {/* Error */}
      {error && (
        <div className="flex items-start gap-2 p-3 rounded-xl bg-destructive/10 border border-destructive/30">
          <AlertTriangle className="w-4 h-4 text-destructive mt-0.5 shrink-0" />
          <p className="text-sm text-destructive">{error}</p>
        </div>
      )}

      {/* Options */}
      <div className="space-y-2">
          {options.map((opt) => {
            const isSelected = selected === opt.id
            const estSize = sizes[opt.id]
            const isUnderLimit = estSize != null && estSize <= maxAllowedSize

            return (
              <button
                key={opt.id}
                onClick={() => setSelected(opt.id)}
                disabled={optimizing}
                className={cn(
                  "w-full text-left px-4 py-3 rounded-xl border transition-all duration-150",
                  "flex items-center justify-between gap-3",
                  isSelected
                    ? "border-primary bg-primary/5 ring-1 ring-primary/30"
                    : "border-border/50 bg-foreground/5 hover:bg-foreground/10",
                  "disabled:opacity-50",
                )}
              >
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium text-foreground truncate">{opt.label}</p>
                  {estSize != null && (
                    <p className="text-xs text-muted-foreground mt-0.5">
                      ~{humanSize(estSize)} · {isUnderLimit ? "✅" : "❌"}
                    </p>
                  )}
                </div>
                <div
                  className={cn(
                    "w-5 h-5 rounded-full border-2 flex items-center justify-center shrink-0 transition-all",
                    isSelected
                      ? "border-primary bg-primary text-primary-foreground"
                      : "border-border/60",
                  )}
                >
                  {isSelected && <Check className="w-3 h-3" />}
                </div>
              </button>
            )
          })}
        </div>

      {/* Buttons */}
      <div className="flex gap-3">
        <button
          onClick={onCancel}
          disabled={optimizing}
          className={cn(
            "flex-1 px-4 py-2.5 rounded-xl",
            "bg-foreground/5 hover:bg-foreground/10",
            "text-sm font-medium text-foreground",
            "transition-all duration-150 active:scale-[0.98]",
            "disabled:opacity-40",
          )}
        >
          {t("optimize.cancel")}
        </button>
        <button
          onClick={handleConfirm}
          disabled={!selected || optimizing}
          className={cn(
            "flex-1 px-4 py-2.5 rounded-xl",
            "bg-primary text-primary-foreground",
            "hover:brightness-110 active:scale-95",
            "text-sm font-medium",
            "transition-all duration-150",
            "disabled:opacity-40 disabled:cursor-not-allowed",
            "flex items-center justify-center gap-2",
          )}
        >
          {optimizing ? (
            <>
              <Loader2 className="w-4 h-4 animate-spin" />
              {t("optimize.processing")}
            </>
          ) : (
            t("optimize.confirm")
          )}
        </button>
      </div>
    </div>
  )
}
