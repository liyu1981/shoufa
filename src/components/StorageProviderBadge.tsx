import { useTranslation } from "react-i18next"

export function StorageProviderBadge({ className }: { className?: string }) {
  const { t } = useTranslation()

  return (
    <p className={className}>
      {t("app.poweredBy", { provider: "shoufad" })}
    </p>
  )
}
