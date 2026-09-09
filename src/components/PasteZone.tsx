"use client"

import { useCallback, useRef, useState } from "react"
import { cn } from "@/lib/utils"
import { Clipboard, Upload, Check } from "lucide-react"

interface PasteZoneProps {
  slug: string
  onAssetAdded: () => void
  ttl: number
}

export function PasteZone({ slug, onAssetAdded, ttl }: PasteZoneProps) {
  const [isDragging, setIsDragging] = useState(false)
  const [uploading, setUploading] = useState(false)
  const [lastAction, setLastAction] = useState<"text" | "image" | null>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const handleTextPaste = useCallback(async (text: string) => {
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

  // Handle paste events on the zone
  const handlePaste = useCallback(async (e: React.ClipboardEvent) => {
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

    // Fall back to text
    const text = e.clipboardData.getData("text/plain")
    if (text) {
      await handleTextPaste(text)
    }
  }, [handleTextPaste, handleImageUpload])

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

    // Try text from drop
    const text = e.dataTransfer.getData("text/plain")
    if (text) {
      await handleTextPaste(text)
    }
  }, [handleTextPaste, handleImageUpload])

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

  return (
    <div
      onPaste={handlePaste}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
      tabIndex={0}
      className={cn(
        "glass-control rounded-2xl p-8 cursor-pointer transition-all duration-200",
        "flex flex-col items-center justify-center gap-4 min-h-[180px]",
        "focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2 focus:ring-offset-background",
        isDragging && "ring-2 ring-ring ring-offset-2 ring-offset-background brightness-[1.06]",
        uploading && "opacity-60 pointer-events-none"
      )}
      onClick={() => fileInputRef.current?.click()}
    >
      <input
        ref={fileInputRef}
        type="file"
        accept="image/*"
        className="hidden"
        onChange={handleFileChange}
      />

      {lastAction === "text" ? (
        <Check className="w-10 h-10 text-success" />
      ) : lastAction === "image" ? (
        <Check className="w-10 h-10 text-success" />
      ) : uploading ? (
        <Upload className="w-10 h-10 text-muted-foreground animate-pulse" />
      ) : (
        <Clipboard className="w-10 h-10 text-muted-foreground" />
      )}

      <div className="text-center">
        {lastAction ? (
          <p className="text-sm font-medium text-success">
            {lastAction === "text" ? "Text saved!" : "Image uploaded!"}
          </p>
        ) : uploading ? (
          <p className="text-sm text-muted-foreground">Uploading...</p>
        ) : (
          <>
            <p className="text-sm font-medium text-foreground/80">
              Ctrl+V to paste text or image
            </p>
            <p className="text-xs text-muted-foreground mt-1">
              or click to upload · drag & drop images
            </p>
          </>
        )}
      </div>
    </div>
  )
}
