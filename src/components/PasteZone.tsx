import { useCallback, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { cn } from "@/lib/utils"
import { isOptimizable } from "@/lib/image-optimize"
import { getEffectiveMimeType, isImageFile } from "@/lib/file-type"
import { Clipboard, Upload, Check, Send, ImageIcon, File as FileIcon, Maximize2 } from "lucide-react"
import { AlertDialog } from "./AlertDialog"
import { ImageOptimizeDialog } from "./ImageOptimizeDialog"
import { TextFocusMode } from "./TextFocusMode"

/** Client-side image limit; the server enforces the same cap. */
const MAX_IMAGE_SIZE = 5 * 1024 * 1024

interface PasteZoneProps {
  slug: string
  onAssetAdded: () => void
  ttl: number
}

function isMobile(): boolean {
  if (typeof navigator === "undefined") return false
  return /iPhone|iPad|iPod|Android/i.test(navigator.userAgent)
}

/** Read a file as a data URL, preserving the effective MIME type. */
function fileToDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result))
    reader.onerror = () => reject(reader.error ?? new Error("Failed to read file"))
    reader.readAsDataURL(file)
  })
}

/** Check whether the browser can actually decode this image type. */
function canDecodeImage(file: File): Promise<boolean> {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file)
    const img = new Image()

    const finish = (result: boolean) => {
      URL.revokeObjectURL(url)
      resolve(result)
    }

    img.onload = () => finish(true)
    img.onerror = () => finish(false)
    img.src = url
  })
}

export function PasteZone({ slug, onAssetAdded, ttl }: PasteZoneProps) {
  const { t } = useTranslation()
  const [isDragging, setIsDragging] = useState(false)
  const [uploading, setUploading] = useState(false)
  const [lastAction, setLastAction] = useState<"text" | "upload" | null>(null)
  const [isMobileDevice] = useState(isMobile)
  const [error, setError] = useState<string | null>(null)
  const [textInput, setTextInput] = useState("")
  // Expanded editor for the text that is about to be sent.
  const [focusMode, setFocusMode] = useState(false)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  // Set while an IME (Chinese/Japanese/Korean...) composition is active. See
  // syncTextFromDom for why the value is mirrored on composition events.
  const composingRef = useRef(false)
  // Image optimization dialog state
  const [optimizeFile, setOptimizeFile] = useState<File | null>(null)
  const [optimizeOpen, setOptimizeOpen] = useState(false)

  const handleTextSubmit = useCallback(async (text: string) => {
    if (!text.trim()) return
    setUploading(true)
    setError(null)
    try {
      const res = await fetch(`/api/${slug}/assets`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content: text, ttl }),
      })
      const data = await res.json().catch(() => null)
      if (res.ok && data?.ok) {
        setLastAction("text")
        setTextInput("")
        setTimeout(() => setLastAction(null), 1500)
        onAssetAdded()
      } else {
        setError(data?.error || "Failed to save text")
        setTimeout(() => setError(null), 5000)
      }
    } catch {
      setError("Failed to save text")
      setTimeout(() => setError(null), 5000)
    } finally {
      setUploading(false)
    }
  }, [slug, ttl, onAssetAdded])

  const handleFileUpload = useCallback(async (file: File) => {
    setUploading(true)
    setError(null)
    try {
      const mimeType = getEffectiveMimeType(file)
      const normalized =
        file.type === mimeType
          ? file
          : new File([file], file.name, {
              type: mimeType || "application/octet-stream",
              lastModified: file.lastModified,
            })
      const dataUrl = await fileToDataUrl(normalized)
      const isImage = mimeType.startsWith("image/")

      const res = await fetch(`/api/${slug}/assets`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          type: isImage ? "image" : "file",
          data: dataUrl,
          mimeType: mimeType || undefined,
          fileName: file.name,
          size: file.size,
          ttl,
        }),
      })
      const data = await res.json().catch(() => null)
      if (res.ok && data?.ok) {
        setLastAction("upload")
        setTimeout(() => setLastAction(null), 1500)
        onAssetAdded()
      } else {
        setError(data?.error || "Upload failed")
        setTimeout(() => setError(null), 5000)
      }
    } catch {
      setError("Upload failed")
      setTimeout(() => setError(null), 5000)
    } finally {
      setUploading(false)
    }
  }, [slug, ttl, onAssetAdded])

  /**
   * Entry point for all file uploads.
   * If the file is an image exceeding the limit and optimizable, show dialog.
   * Otherwise upload directly.
   */
  const handleFile = useCallback(
    async (file: File) => {
      const isImage = isImageFile(file)

      // Formats such as HEIC can be decoded by Safari but not by Chrome, and
      // some formats (TIFF, etc.) cannot be previewed by any browser. Reject
      // them early with a clear message instead of uploading a broken image
      // preview. The "Upload file" button still allows sharing them as files.
      if (isImage && !isOptimizable(file)) {
        const decodable = await canDecodeImage(file)
        if (!decodable) {
          setError(t("paste.unsupportedImage"))
          setTimeout(() => setError(null), 7000)
          return
        }
      }

      if (isImage && file.size > MAX_IMAGE_SIZE && isOptimizable(file)) {
        // Show optimization dialog — upload will happen on confirm
        setOptimizeFile(file)
        setOptimizeOpen(true)
        return
      }

      // Non-image or under limit — upload directly
      await handleFileUpload(file)
    },
    [handleFileUpload, t],
  )

  /** Called when user picks an optimization in the dialog */
  const handleOptimizeConfirm = useCallback(
    async (optimized: File) => {
      setOptimizeOpen(false)
      setOptimizeFile(null)
      await handleFileUpload(optimized)
    },
    [handleFileUpload],
  )

  /** Called when user cancels the dialog */
  const handleOptimizeCancel = useCallback(() => {
    setOptimizeOpen(false)
    setOptimizeFile(null)
  }, [])

  // Handle paste events on the zone (desktop Ctrl+V)
  const handlePaste = useCallback(async (e: React.ClipboardEvent) => {
    // If textarea is focused, let the native paste happen
    if (document.activeElement === textareaRef.current) {
      return // Let onChange handle it
    }

    e.preventDefault()

    // Check for images in clipboard
    const items = Array.from(e.clipboardData.items)
    const imageItem = items.find(item => item.type.startsWith("image/"))

    if (imageItem) {
      const file = imageItem.getAsFile()
      if (file) {
        await handleFile(file)
        return
      }
    }

    // Fall back to text — put it in the textarea
    const text = e.clipboardData.getData("text/plain")
    if (text) {
      setTextInput(text)
    }
  }, [handleFile])

  // Handle drag and drop
  const handleDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault()
    setIsDragging(true)
  }, [])

  const handleDragLeave = useCallback((e: React.DragEvent) => {
    e.preventDefault()
    setIsDragging(false)
  }, [])

  const handleDrop = useCallback(async (e: React.DragEvent) => {
    e.preventDefault()
    setIsDragging(false)

    const files = Array.from(e.dataTransfer.files)
    if (files.length > 0) {
      await handleFile(files[0])
      return
    }

    const text = e.dataTransfer.getData("text/plain")
    if (text) {
      setTextInput(text)
    }
  }, [handleFile])

  // Handle file input
  const handleFileChange = useCallback(async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (file) {
      await handleFile(file)
    }
    if (fileInputRef.current) {
      fileInputRef.current.value = ""
    }
  }, [handleFile])

  /**
   * The textarea is controlled, so React rewrites its value on every render.
   * During an IME composition the DOM value can run ahead of React state (the
   * composition update lands before the input event), and a re-render in that
   * gap — the room polls in the background — resets the field and makes the IME
   * re-insert its buffer, producing duplicated characters. Mirroring the DOM
   * value on every composition event keeps state and DOM in lockstep.
   */
  const syncTextFromDom = useCallback((e: React.SyntheticEvent<HTMLTextAreaElement>) => {
    setTextInput(e.currentTarget.value)
  }, [])

  const canSubmit = textInput.trim().length > 0

  const handleFocusSubmit = useCallback(async () => {
    if (!textInput.trim()) return
    // Leave focus mode right away; the compact view shows the progress and the
    // text is only cleared once the server accepted it.
    setFocusMode(false)
    await handleTextSubmit(textInput)
  }, [textInput, handleTextSubmit])

  const closeFocusMode = useCallback(() => {
    setFocusMode(false)
    textareaRef.current?.focus()
  }, [])

  return (
    <div
      onPaste={handlePaste}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
      className={cn(
        "glass-control rounded-2xl p-6 transition-all duration-200",
        "flex flex-col gap-4",
        isDragging && "ring-2 ring-ring ring-offset-2 ring-offset-background brightness-[1.06]",
        uploading && "opacity-60 pointer-events-none"
      )}
    >
      <input
        ref={fileInputRef}
        type="file"
        className="hidden"
        onChange={handleFileChange}
      />

      {/* Status indicator */}
      <div className="flex items-center gap-3">
        {lastAction === "text" ? (
          <Check className="w-5 h-5 text-success shrink-0" />
        ) : lastAction === "upload" ? (
          <Check className="w-5 h-5 text-success shrink-0" />
        ) : uploading ? (
          <Upload className="w-5 h-5 text-muted-foreground animate-pulse shrink-0" />
        ) : (
          <Clipboard className="w-5 h-5 text-muted-foreground shrink-0" />
        )}

        {lastAction ? (
          <p className="text-sm font-medium text-success">
            {lastAction === "text" ? t("paste.saved") : t("paste.uploaded")}
          </p>
        ) : uploading ? (
          <p className="text-sm text-muted-foreground">{t("paste.uploading")}</p>
        ) : (
          <p className="text-sm text-muted-foreground">
            {isMobileDevice ? t("paste.hintMobile") : t("paste.hint")}
          </p>
        )}
      </div>

      {/* Text input area */}
      <div className="flex gap-2">
        <textarea
          ref={textareaRef}
          value={textInput}
          onChange={(e) => setTextInput(e.target.value)}
          onCompositionStart={(e) => {
            composingRef.current = true
            syncTextFromDom(e)
          }}
          onCompositionUpdate={syncTextFromDom}
          onCompositionEnd={(e) => {
            composingRef.current = false
            syncTextFromDom(e)
          }}
          onKeyDown={(e) => {
            // Enter also confirms IME candidates; never treat those as submit.
            if (e.nativeEvent.isComposing || composingRef.current) return
            // Cmd+Enter (Mac) or Ctrl+Enter (others) submits from the compact view.
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault()
              if (canSubmit) handleTextSubmit(textInput)
              return
            }
            // Plain Enter opens the focus editor; Shift+Enter keeps the newline
            // and mobile keyboards keep their native Enter behaviour.
            if (e.key === "Enter" && !e.shiftKey && !isMobileDevice) {
              e.preventDefault()
              setFocusMode(true)
            }
          }}
          placeholder={t("paste.placeholder")}
          rows={2}
          className="flex-1 px-4 py-3 rounded-xl bg-foreground/5 border border-border/50
                     text-foreground placeholder:text-muted-foreground/50 text-sm
                     focus:outline-none focus:ring-2 focus:ring-ring/50
                     transition-all duration-200 resize-none"
        />

        <button
          onClick={() => handleTextSubmit(textInput)}
          disabled={!canSubmit}
          className={cn(
            "px-3 rounded-xl transition-all duration-150 flex items-center justify-center",
            canSubmit
              ? "bg-primary text-primary-foreground hover:brightness-110 active:scale-95"
              : "bg-foreground/5 text-muted-foreground/40 cursor-not-allowed"
          )}
          title={t("paste.submit")}
        >
          <Send className="w-4 h-4" />
        </button>

        <button
          onClick={() => setFocusMode(true)}
          className="px-3 rounded-xl bg-foreground/5 text-muted-foreground hover:bg-foreground/10
                     hover:text-foreground active:scale-95 transition-all duration-150
                     flex items-center justify-center"
          title={t("paste.focusOpen")}
          aria-label={t("paste.focusOpen")}
        >
          <Maximize2 className="w-4 h-4" />
        </button>
      </div>

      {/* Upload buttons */}
      <div className="flex gap-2">
        <button
          onClick={() => {
            if (fileInputRef.current) {
              fileInputRef.current.accept = "image/*"
              fileInputRef.current.click()
            }
          }}
          className="flex-1 px-4 py-2.5 rounded-xl bg-foreground/5 text-muted-foreground
                     hover:bg-foreground/10 hover:text-foreground
                     active:scale-[0.99] transition-all duration-150
                     flex items-center justify-center gap-2 text-sm"
        >
          <ImageIcon className="w-4 h-4" />
          <span>{t("paste.uploadImage")}</span>
        </button>

        <button
          onClick={() => {
            if (fileInputRef.current) {
              fileInputRef.current.accept = "*/*"
              fileInputRef.current.click()
            }
          }}
          className="flex-1 px-4 py-2.5 rounded-xl bg-foreground/5 text-muted-foreground
                     hover:bg-foreground/10 hover:text-foreground
                     active:scale-[0.99] transition-all duration-150
                     flex items-center justify-center gap-2 text-sm"
        >
          <FileIcon className="w-4 h-4" />
          <span>{t("paste.uploadFile")}</span>
        </button>
      </div>

      {/* Focus mode editor for the pending text */}
      <TextFocusMode
        open={focusMode}
        value={textInput}
        busy={uploading}
        onChange={setTextInput}
        onSubmit={handleFocusSubmit}
        onClose={closeFocusMode}
      />

      {/* Error dialog */}
      <AlertDialog
        open={!!error}
        onClose={() => setError(null)}
        message={error || ""}
      />

      {/* Image optimization dialog */}
      <ImageOptimizeDialog
        open={optimizeOpen}
        file={optimizeFile}
        maxAllowedSize={MAX_IMAGE_SIZE}
        onConfirm={handleOptimizeConfirm}
        onCancel={handleOptimizeCancel}
      />
    </div>
  )
}
