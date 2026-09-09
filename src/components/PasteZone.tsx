"use client"

import { useCallback, useRef, useState, useEffect } from "react"
import { cn } from "@/lib/utils"
import { Clipboard, Upload, Check, Send } from "lucide-react"

interface PasteZoneProps {
  slug: string
  onAssetAdded: () => void
  ttl: number
}

function isMobile(): boolean {
  if (typeof navigator === "undefined") return false
  return /iPhone|iPad|iPod|Android/i.test(navigator.userAgent)
}

export function PasteZone({ slug, onAssetAdded, ttl }: PasteZoneProps) {
  const [isDragging, setIsDragging] = useState(false)
  const [uploading, setUploading] = useState(false)
  const [lastAction, setLastAction] = useState<"text" | "image" | null>(null)
  const [isMobileDevice, setIsMobileDevice] = useState(false)
  const [textInput, setTextInput] = useState("")
  const fileInputRef = useRef<HTMLInputElement>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)

  useEffect(() => {
    setIsMobileDevice(isMobile())
  }, [])

  const handleTextSubmit = useCallback(async (text: string) => {
    if (!text.trim()) return
    setUploading(true)
    try {
      const res = await fetch(`/api/${slug}/assets`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content: text, ttl }),
      })
      if (res.ok) {
        setLastAction("text")
        setTextInput("")
        setTimeout(() => setLastAction(null), 1500)
        onAssetAdded()
      }
    } finally {
      setUploading(false)
    }
  }, [slug, ttl, onAssetAdded])

  const handleImageUpload = useCallback(async (file: File) => {
    setUploading(true)
    try {
      const formData = new FormData()
      formData.append("file", file)
      formData.append("ttl", String(ttl))
      const res = await fetch(`/api/${slug}/assets`, {
        method: "POST",
        body: formData,
      })
      if (res.ok) {
        setLastAction("image")
        setTimeout(() => setLastAction(null), 1500)
        onAssetAdded()
      }
    } finally {
      setUploading(false)
    }
  }, [slug, ttl, onAssetAdded])

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
        await handleImageUpload(file)
        return
      }
    }

    // Fall back to text — put it in the textarea
    const text = e.clipboardData.getData("text/plain")
    if (text) {
      setTextInput(text)
    }
  }, [handleImageUpload])

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
    const imageFile = files.find(f => f.type.startsWith("image/"))
    if (imageFile) {
      await handleImageUpload(imageFile)
      return
    }

    const text = e.dataTransfer.getData("text/plain")
    if (text) {
      setTextInput(text)
    }
  }, [handleImageUpload])

  // Handle file input
  const handleFileChange = useCallback(async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (file && file.type.startsWith("image/")) {
      await handleImageUpload(file)
    }
    if (fileInputRef.current) {
      fileInputRef.current.value = ""
    }
  }, [handleImageUpload])

  const canSubmit = textInput.trim().length > 0

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
        accept="image/*"
        className="hidden"
        onChange={handleFileChange}
      />

      {/* Status indicator */}
      <div className="flex items-center gap-3">
        {lastAction === "text" ? (
          <Check className="w-5 h-5 text-success shrink-0" />
        ) : lastAction === "image" ? (
          <Check className="w-5 h-5 text-success shrink-0" />
        ) : uploading ? (
          <Upload className="w-5 h-5 text-muted-foreground animate-pulse shrink-0" />
        ) : (
          <Clipboard className="w-5 h-5 text-muted-foreground shrink-0" />
        )}

        {lastAction ? (
          <p className="text-sm font-medium text-success">
            {lastAction === "text" ? "Text saved!" : "Image uploaded!"}
          </p>
        ) : uploading ? (
          <p className="text-sm text-muted-foreground">Uploading...</p>
        ) : (
          <p className="text-sm text-muted-foreground">
            {isMobileDevice ? "Type or paste text, or upload an image" : "Type, paste (Ctrl+V), or upload an image"}
          </p>
        )}
      </div>

      {/* Text input area */}
      <div className="flex gap-2">
        <textarea
          ref={textareaRef}
          value={textInput}
          onChange={(e) => setTextInput(e.target.value)}
          onKeyDown={(e) => {
            // Submit on Cmd+Enter (Mac) or Ctrl+Enter (others)
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault()
              if (canSubmit) handleTextSubmit(textInput)
            }
          }}
          placeholder="Paste or type text here..."
          rows={2}
          className="flex-1 px-4 py-3 rounded-xl bg-foreground/5 border border-border/50
                     text-foreground placeholder:text-muted-foreground/50 text-sm
                     focus:outline-none focus:ring-2 focus:ring-ring/50
                     transition-all duration-200 resize-none"
        />

        <div className="flex flex-col gap-2">
          <button
            onClick={() => handleTextSubmit(textInput)}
            disabled={!canSubmit}
            className={cn(
              "px-3 py-2 rounded-xl transition-all duration-150 flex items-center justify-center",
              canSubmit
                ? "bg-primary text-primary-foreground hover:brightness-110 active:scale-95"
                : "bg-foreground/5 text-muted-foreground/40 cursor-not-allowed"
            )}
            title="Submit (⌘+Enter)"
          >
            <Send className="w-4 h-4" />
          </button>

          <button
            onClick={() => fileInputRef.current?.click()}
            className="px-3 py-2 rounded-xl bg-foreground/5 text-muted-foreground
                       hover:bg-foreground/10 hover:text-foreground
                       active:scale-95 transition-all duration-150
                       flex items-center justify-center"
            title="Upload image"
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <rect width="18" height="18" x="3" y="3" rx="2" ry="2"/>
              <circle cx="9" cy="9" r="2"/>
              <path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>
            </svg>
          </button>
        </div>
      </div>
    </div>
  )
}
