import { defineConfig, loadEnv } from "vite"
import react from "@vitejs/plugin-react"
import tailwindcss from "@tailwindcss/vite"
import { fileURLToPath, URL } from "node:url"

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "")
  const siteUrl = env.VITE_SITE_URL || "http://localhost:8079"

  return {
    plugins: [
      react(),
      tailwindcss(),
      {
        name: "shoufa-site-url",
        transformIndexHtml(html) {
          return html.replaceAll("%SITE_URL%", siteUrl)
        },
      },
    ],
    resolve: {
      alias: {
        "@": fileURLToPath(new URL("./src", import.meta.url)),
      },
    },
    build: {
      outDir: "server/src/web",
      emptyOutDir: true,
      modulePreload: { polyfill: false },
    },
    server: {
      port: 3210,
      host: true,
      proxy: {
        "/api": { target: "http://127.0.0.1:8079", changeOrigin: false },
        "/wait": { target: "http://127.0.0.1:8079", changeOrigin: false },
        "/health": { target: "http://127.0.0.1:8079", changeOrigin: false },
        "/healthz": { target: "http://127.0.0.1:8079", changeOrigin: false },
      },
    },
  }
})
