import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { RouterProvider } from "@tanstack/react-router"
import { I18nProvider } from "@/components/I18nProvider"
import { ThemeProvider } from "@/components/ThemeProvider"
import { ServiceWorkerRegistration } from "@/components/ServiceWorkerRegistration"
import { router } from "@/router"
import "@/styles.css"

// Apply the persisted theme before React paints to avoid a flash.
let storedTheme: string | null = null
try {
  storedTheme = localStorage.getItem("theme")
} catch {
  // Storage may be unavailable in private/embedded browsers.
}
const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches
const dark = storedTheme === "dark" || ((!storedTheme || storedTheme === "system") && prefersDark)
document.documentElement.classList.toggle("dark", dark)
document.documentElement.style.colorScheme = dark ? "dark" : "light"

const root = document.getElementById("root")
if (!root) throw new Error("Missing #root element")

createRoot(root).render(
  <StrictMode>
    <I18nProvider>
      <ThemeProvider>
        <RouterProvider router={router} />
        <ServiceWorkerRegistration />
      </ThemeProvider>
    </I18nProvider>
  </StrictMode>,
)
