"use client"

import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import type { StorageProviderInfo } from "@/lib/storage/types"

interface ConfigResponse {
  data?: {
    storage?: StorageProviderInfo
  }
}

let cachedProvider: StorageProviderInfo | null = null
let providerPromise: Promise<StorageProviderInfo | null> | null = null

async function fetchStorageProvider(): Promise<StorageProviderInfo | null> {
  try {
    const res = await fetch("/api/config", { cache: "no-store" })
    if (!res.ok) return null

    const payload = (await res.json()) as ConfigResponse
    const storage = payload.data?.storage
    return storage?.displayName ? storage : null
  } catch {
    return null
  }
}

function loadStorageProvider(): Promise<StorageProviderInfo | null> {
  if (cachedProvider) return Promise.resolve(cachedProvider)
  if (providerPromise) return providerPromise

  providerPromise = fetchStorageProvider()
    .then((storage) => {
      cachedProvider = storage
      return storage
    })
    .finally(() => {
      providerPromise = null
    })

  return providerPromise
}

/**
 * Small footer line that reports the active storage backend.
 *
 * The provider is resolved by /api/config at runtime, so static pages still
 * reflect the deployment's actual environment.
 */
export function StorageProviderBadge({ className }: { className?: string }) {
  const { t } = useTranslation()
  const [provider, setProvider] = useState<StorageProviderInfo | null>(cachedProvider)

  useEffect(() => {
    let cancelled = false

    loadStorageProvider().then((storage) => {
      if (!cancelled && storage) setProvider(storage)
    })

    return () => {
      cancelled = true
    }
  }, [])

  if (!provider) return null

  return (
    <p className={className}>
      {t("app.poweredBy", { provider: provider.displayName })}
    </p>
  )
}
