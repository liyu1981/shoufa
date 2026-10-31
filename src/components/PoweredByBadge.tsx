import { useTranslation } from "react-i18next"

export function PoweredByBadge({ className }: { className?: string }) {
  const { t } = useTranslation()

  return (
    <p className={className}>
      {t("app.poweredBy", { provider: "shoufad" })} · v{__APP_VERSION__}
    </p>
  )
}
