"use client"

import { useCallback, useState } from "react"
import { cn } from "@/lib/utils"
import { Copy, Download, Trash2, Check, FileText, ImageIcon } from "lucide-react"
import type { Asset } from "@/lib/atoms"
import { CountdownTimer } from "./CountdownTimer"

interface AssetCardProps {
  asset: Asset
  slug: string
  onDelete: (id: string) => void
}

export function AssetCard({ asset, slug, onDelete }: AssetCardProps) {
  const [copied, setCopied] = useState(false)
  const [deleting, setDeleting] = useState(false)

  const handleCopy = useCallback(async () => {
    if (asset.type !== "text" || !asset.content) return
    await navigator.clipboard.writeText(asset.content)
    setCopied(true)
    setTimeout(() => setCopied(false), 1500)
  }, [asset])

  const handleDownload = useCallback(() => {
    if (asset.type !== "image" || !asset.data) return
    const link = document.createElement("a")
    link.href = asset.data
    link.download = asset.fileName || "image"
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
  }, [asset])

  const handleDelete = useCallback(async () => {
    setDeleting(true)
    try {
      const res = await fetch(`/api/${slug}/assets/${asset.id}`, { method: "DELETE" })
      if (res.ok) {
        onDelete(asset.id)
      }
    } finally {
      setDeleting(false)
    }
  }, [slug, asset.id, onDelete])

  const isExpired = Date.now() > asset.expiresAt

  if (isExpired) return null

  return (
    <div
      className={cn(
        "glass-control rounded-xl overflow-hidden transition-all duration-200",
        "hover:brightness-[1.04] hover:-translate-y-px",
        deleting && "opacity-40 scale-95"
      )}
    >
      {/* Asset content */}
      {asset.type === "text" ? (
        <div className="p-4">
          <div className="flex items-start gap-3">
            <FileText className="w-4 h-4 text-muted-foreground mt-0.5 shrink-0" />
            <pre className="text-sm font-mono whitespace-pre-wrap break-all text-foreground/90 leading-relaxed max-h-[200px] overflow-y-auto">
              {asset.content}
            </pre>
          </div>
        </div>
      ) : (
        <div className="p-2">
          <div className="relative rounded-lg overflow-hidden bg-muted/30">
            <img
              src={asset.data}
              alt={asset.fileName || "Pasted image"}
              className="w-full h-auto max-h-[300px] object-contain"
            />
          </div>
          {asset.fileName && (
            <div className="flex items-center gap-2 mt-2 px-2">
              <ImageIcon className="w-3 h-3 text-muted-foreground" />
              <span className="text-xs text-muted-foreground truncate">{asset.fileName}</span>
            </div>
          )}
        </div>
      )}

      {/* Actions bar */}
      <div className="flex items-center justify-between px-4 py-2.5 border-t border-border/30">
        <CountdownTimer expiresAt={asset.expiresAt} />

        <div className="flex items-center gap-1">
          {asset.type === "text" && (
            <button
              onClick={handleCopy}
              className={cn(
                "p-1.5 rounded-lg transition-all duration-150",
                "hover:bg-foreground/5 active:scale-95",
                copied && "text-success"
              )}
              title="Copy to clipboard"
            >
              {copied ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
            </button>
          )}
          {asset.type === "image" && (
            <button
              onClick={handleDownload}
              className="p-1.5 rounded-lg transition-all duration-150 hover:bg-foreground/5 active:scale-95"
              title="Download image"
            >
              <Download className="w-4 h-4" />
            </button>
          )}
          <button
            onClick={handleDelete}
            disabled={deleting}
            className="p-1.5 rounded-lg transition-all duration-150 hover:bg-destructive/10 hover:text-destructive active:scale-95"
            title="Delete"
          >
            <Trash2 className="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
  )
}
