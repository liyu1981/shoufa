import { useCallback, useEffect, useRef } from "react"
import { createPortal } from "react-dom"
import { useTranslation } from "react-i18next"
import { Loader2, Minimize2, Send } from "lucide-react"
import { cn } from "@/lib/utils"

interface TextFocusModeProps {
  open: boolean
  value: string
  /** True while the text is being submitted. */
  busy?: boolean
  onChange: (value: string) => void
  onSubmit: () => void
  onClose: () => void
}

/**
 * Expanded, distraction-free editor for the text that is about to be sent.
 * The compact textarea in PasteZone opens it on Enter (or via its expand
 * button); Esc returns to the compact view and Cmd/Ctrl+Enter sends.
 */
export function TextFocusMode({
  open,
  value,
  busy = false,
  onChange,
  onSubmit,
  onClose,
}: TextFocusModeProps) {
  const { t } = useTranslation()
  const textareaRef = useRef<HTMLTextAreaElement>(null)

  // Focus the editor when the mode opens, with the caret at the end.
  useEffect(() => {
    if (!open) return
    const el = textareaRef.current
    if (!el) return
    el.focus()
    const end = el.value.length
    try {
      el.setSelectionRange(end, end)
    } catch {
      // Some browsers refuse setSelectionRange on unfocused elements.
    }
  }, [open])

  /**
   * Mirror the DOM value on composition events so an IME composition is never
   * reset by a re-render with a one-tick-stale value (see PasteZone).
   */
  const syncFromDom = useCallback(
    (e: React.SyntheticEvent<HTMLTextAreaElement>) => onChange(e.currentTarget.value),
    [onChange],
  )

  const canSubmit = value.trim().length > 0

  if (!open) return null

  return createPortal(
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
      {/* Backdrop */}
      <div className="absolute inset-0 bg-black/50 backdrop-blur-sm" onClick={onClose} />

      <div
        className={cn(
          "relative z-10 w-full max-w-2xl h-[min(80vh,40rem)] flex flex-col gap-3",
          "bg-card border border-border/50 rounded-2xl shadow-xl p-5",
          "animate-in fade-in zoom-in-95 duration-200",
        )}
      >
        {/* Header */}
        <div className="flex items-center justify-between gap-3">
          <div className="min-w-0">
            <h3 className="text-base font-semibold text-foreground">{t("paste.focusMode")}</h3>
            <p className="text-xs text-muted-foreground mt-0.5">
              {t("paste.focusChars", { count: value.length })}
            </p>
          </div>
          <button
            onClick={onClose}
            className="p-2 rounded-lg text-muted-foreground hover:bg-foreground/5 hover:text-foreground transition-all"
            title={t("paste.focusDone")}
            aria-label={t("paste.focusDone")}
          >
            <Minimize2 className="w-4 h-4" />
          </button>
        </div>

        {/* Editor */}
        <textarea
          ref={textareaRef}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onCompositionStart={syncFromDom}
          onCompositionUpdate={syncFromDom}
          onCompositionEnd={syncFromDom}
          onKeyDown={(e) => {
            // Enter confirms IME candidates; never treat it as a shortcut.
            if (e.nativeEvent.isComposing) return
            if (e.key === "Escape") {
              e.preventDefault()
              onClose()
              return
            }
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault()
              if (canSubmit) onSubmit()
            }
          }}
          placeholder={t("paste.placeholder")}
          spellCheck={false}
          className="flex-1 min-h-0 px-4 py-3 rounded-xl bg-foreground/5 border border-border/50
                     text-foreground placeholder:text-muted-foreground/50 text-sm leading-relaxed
                     focus:outline-none focus:ring-2 focus:ring-ring/50
                     transition-all duration-200 resize-none"
        />

        {/* Footer */}
        <div className="flex items-center justify-between gap-3">
          <p className="text-xs text-muted-foreground/70">{t("paste.focusHint")}</p>
          <button
            onClick={() => canSubmit && onSubmit()}
            disabled={!canSubmit || busy}
            className={cn(
              "px-4 py-2 rounded-xl text-sm flex items-center gap-2 transition-all duration-150",
              canSubmit && !busy
                ? "bg-primary text-primary-foreground hover:brightness-110 active:scale-95"
                : "bg-foreground/5 text-muted-foreground/40 cursor-not-allowed",
            )}
            title={t("paste.submit")}
          >
            {busy ? (
              <Loader2 className="w-4 h-4 animate-spin" />
            ) : (
              <Send className="w-4 h-4" />
            )}
            <span>{busy ? t("paste.uploading") : t("paste.submit")}</span>
          </button>
        </div>
      </div>
    </div>,
    document.body,
  )
}
