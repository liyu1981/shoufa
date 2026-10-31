import { useCallback, useEffect, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { useTranslation } from "react-i18next"
import { RotateCcw, X, ZoomIn, ZoomOut } from "lucide-react"
import { cn } from "@/lib/utils"

interface ImageLightboxProps {
  open: boolean
  src: string
  alt: string
  fileName?: string
  onClose: () => void
}

interface View {
  scale: number
  x: number
  y: number
}

const MIN_SCALE = 1
const MAX_SCALE = 8
const ZOOM_STEP = 1.3

const INITIAL_VIEW: View = { scale: 1, x: 0, y: 0 }

function clampScale(scale: number): number {
  return Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale))
}

function clampPan(
  scale: number,
  x: number,
  y: number,
  container: HTMLDivElement | null,
  image: HTMLImageElement | null,
): Pick<View, "x" | "y"> {
  if (scale <= MIN_SCALE) return { x: 0, y: 0 }
  if (!container || !image) return { x, y }

  const maxX = Math.max(0, (image.offsetWidth * scale - container.clientWidth) / 2)
  const maxY = Math.max(0, (image.offsetHeight * scale - container.clientHeight) / 2)

  return {
    x: Math.min(maxX, Math.max(-maxX, x)),
    y: Math.min(maxY, Math.max(-maxY, y)),
  }
}

export function ImageLightbox(props: ImageLightboxProps) {
  if (!props.open) return null

  return createPortal(<ImageLightboxInner {...props} />, document.body)
}

function ImageLightboxInner({
  src,
  alt,
  fileName,
  onClose,
}: Omit<ImageLightboxProps, "open">) {
  const { t } = useTranslation()
  const [view, setView] = useState<View>(INITIAL_VIEW)
  const [dragging, setDragging] = useState(false)
  const containerRef = useRef<HTMLDivElement>(null)
  const imageRef = useRef<HTMLImageElement>(null)
  const dragRef = useRef<{
    pointerId: number
    startX: number
    startY: number
    originX: number
    originY: number
  } | null>(null)

  // Lock page scroll while the lightbox is open.
  useEffect(() => {
    const previous = document.body.style.overflow
    document.body.style.overflow = "hidden"
    return () => {
      document.body.style.overflow = previous
    }
  }, [])

  const zoomBy = useCallback((factor: number) => {
    setView((prev) => {
      const scale = clampScale(prev.scale * factor)
      if (scale === prev.scale) return prev
      if (scale === MIN_SCALE) return INITIAL_VIEW

      const ratio = scale / prev.scale
      const next = clampPan(
        scale,
        prev.x * ratio,
        prev.y * ratio,
        containerRef.current,
        imageRef.current,
      )
      return { scale, x: next.x, y: next.y }
    })
  }, [])

  const resetView = useCallback(() => setView(INITIAL_VIEW), [])

  const toggleZoom = useCallback(() => {
    setView((prev) => (prev.scale > MIN_SCALE ? INITIAL_VIEW : { scale: 2, x: 0, y: 0 }))
  }, [])

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose()
      } else if (event.key === "+" || event.key === "=") {
        zoomBy(ZOOM_STEP)
      } else if (event.key === "-" || event.key === "_") {
        zoomBy(1 / ZOOM_STEP)
      } else if (event.key === "0") {
        resetView()
      }
    }

    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  }, [onClose, resetView, zoomBy])

  // Wheel zoom around the cursor.
  useEffect(() => {
    const element = containerRef.current
    if (!element) return

    const onWheel = (event: WheelEvent) => {
      event.preventDefault()
      const rect = element.getBoundingClientRect()
      const anchorX = event.clientX - rect.left - rect.width / 2
      const anchorY = event.clientY - rect.top - rect.height / 2

      setView((prev) => {
        const factor = event.deltaY < 0 ? 1.15 : 1 / 1.15
        const scale = clampScale(prev.scale * factor)
        if (scale === prev.scale) return prev
        if (scale === MIN_SCALE) return INITIAL_VIEW

        const ratio = scale / prev.scale
        const x = anchorX - (anchorX - prev.x) * ratio
        const y = anchorY - (anchorY - prev.y) * ratio
        const next = clampPan(scale, x, y, element, imageRef.current)
        return { scale, x: next.x, y: next.y }
      })
    }

    element.addEventListener("wheel", onWheel, { passive: false })
    return () => element.removeEventListener("wheel", onWheel)
  }, [])

  const handlePointerDown = useCallback(
    (event: React.PointerEvent<HTMLDivElement>) => {
      if (view.scale <= MIN_SCALE) return

      event.currentTarget.setPointerCapture(event.pointerId)
      dragRef.current = {
        pointerId: event.pointerId,
        startX: event.clientX,
        startY: event.clientY,
        originX: view.x,
        originY: view.y,
      }
      setDragging(true)
    },
    [view],
  )

  const handlePointerMove = useCallback((event: React.PointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return

    const x = drag.originX + event.clientX - drag.startX
    const y = drag.originY + event.clientY - drag.startY

    setView((prev) => {
      const next = clampPan(
        prev.scale,
        x,
        y,
        containerRef.current,
        imageRef.current,
      )
      return { ...prev, x: next.x, y: next.y }
    })
  }, [])

  const endDrag = useCallback((event: React.PointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return

    dragRef.current = null
    setDragging(false)
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
  }, [])

  const handleContainerClick = useCallback(
    (event: React.MouseEvent<HTMLDivElement>) => {
      if (event.target === event.currentTarget && view.scale === MIN_SCALE) {
        onClose()
      }
    },
    [onClose, view.scale],
  )

  const atMinZoom = view.scale <= MIN_SCALE
  const atMaxZoom = view.scale >= MAX_SCALE
  const resetDisabled = view.scale === MIN_SCALE && view.x === 0 && view.y === 0

  return (
    <div
      className="fixed inset-0 z-[100] bg-black/90 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
      aria-label={t("lightbox.title")}
    >
      <div className="flex h-full flex-col">
        <div className="flex items-center justify-between gap-4 px-4 py-3">
          <p className="truncate text-sm text-white/80">{fileName || alt}</p>
          <button
            type="button"
            onClick={onClose}
            autoFocus
            aria-label={t("lightbox.close")}
            title={t("lightbox.close")}
            className="rounded-full p-2 text-white/70 transition-colors hover:bg-white/10 hover:text-white focus:outline-none focus-visible:ring-2 focus-visible:ring-white/50"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <div
          ref={containerRef}
          className={cn(
            "relative flex flex-1 min-h-0 touch-none select-none items-center justify-center overflow-hidden overscroll-contain",
            atMinZoom ? "cursor-zoom-in" : dragging ? "cursor-grabbing" : "cursor-grab",
          )}
          onPointerDown={handlePointerDown}
          onPointerMove={handlePointerMove}
          onPointerUp={endDrag}
          onPointerCancel={endDrag}
          onClick={handleContainerClick}
          onDoubleClick={toggleZoom}
        >
          <img
            ref={imageRef}
            src={src}
            alt={alt}
            draggable={false}
            className="max-h-full max-w-full object-contain will-change-transform"
            style={{
              transform: `translate3d(${view.x}px, ${view.y}px, 0) scale(${view.scale})`,
            }}
          />
        </div>

        <div className="flex items-center justify-center gap-2 px-4 py-4">
          <button
            type="button"
            onClick={() => zoomBy(1 / ZOOM_STEP)}
            disabled={atMinZoom}
            aria-label={t("lightbox.zoomOut")}
            title={t("lightbox.zoomOut")}
            className="rounded-full p-2 text-white/70 transition-colors hover:bg-white/10 hover:text-white disabled:opacity-30 focus:outline-none focus-visible:ring-2 focus-visible:ring-white/50"
          >
            <ZoomOut className="h-5 w-5" />
          </button>
          <span className="w-14 text-center text-xs tabular-nums text-white/70">
            {Math.round(view.scale * 100)}%
          </span>
          <button
            type="button"
            onClick={() => zoomBy(ZOOM_STEP)}
            disabled={atMaxZoom}
            aria-label={t("lightbox.zoomIn")}
            title={t("lightbox.zoomIn")}
            className="rounded-full p-2 text-white/70 transition-colors hover:bg-white/10 hover:text-white disabled:opacity-30 focus:outline-none focus-visible:ring-2 focus-visible:ring-white/50"
          >
            <ZoomIn className="h-5 w-5" />
          </button>
          <button
            type="button"
            onClick={resetView}
            disabled={resetDisabled}
            aria-label={t("lightbox.reset")}
            title={t("lightbox.reset")}
            className="rounded-full p-2 text-white/70 transition-colors hover:bg-white/10 hover:text-white disabled:opacity-30 focus:outline-none focus-visible:ring-2 focus-visible:ring-white/50"
          >
            <RotateCcw className="h-4 w-4" />
          </button>
          <span className="ml-2 hidden text-xs text-white/40 sm:inline">
            {t("lightbox.hint")}
          </span>
        </div>
      </div>
    </div>
  )
}
