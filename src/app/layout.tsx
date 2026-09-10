import type { Metadata, Viewport } from "next"
import { Geist, Geist_Mono } from "next/font/google"
import { ThemeProvider } from "@/components/ThemeProvider"
import { I18nProvider } from "@/components/I18nProvider"
import { ServiceWorkerRegistration } from "@/components/ServiceWorkerRegistration"
import { GoogleAnalytics } from "@next/third-parties/google"
import "./globals.css"

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
})

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
})

const siteUrl = process.env.NEXT_PUBLIC_SITE_URL || "https://shoufa.vercel.app"
const gaId = process.env.NEXT_PUBLIC_GA_ID || "G-XXXXXXXXXX"

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: {
    default: "Shoufa — Paste, Share, Disappear",
    template: "%s · Shoufa",
  },
  description:
    "Free ephemeral clipboard with a time limit. Paste text or images, share a memorable link like bright-fox, and content auto-expires. No signup. Perfect for sharing code snippets, passwords, and one-time secrets between devices.",
  keywords: [
    "ephemeral clipboard",
    "temporary paste",
    "self-destructing text",
    "share code snippets",
    "share passwords securely",
    "one-time secret sharing",
    "paste text online",
    "share images temporarily",
    "disappearing messages",
    "clipboard sharing between devices",
    "no signup paste tool",
    "temporary file sharing",
  ],
  authors: [{ name: "liyu1981" }],
  creator: "liyu1981",
  icons: {
    icon: "/api/favicon",
  },
  openGraph: {
    type: "website",
    url: siteUrl,
    siteName: "Shoufa",
    title: "Shoufa — Paste, Share, Disappear",
    description:
      "Ephemeral clipboard with a time limit. Paste text or images, share a memorable link, and it auto-expires. No signup needed.",
  },
  twitter: {
    card: "summary",
    title: "Shoufa — Paste, Share, Disappear",
    description:
      "Ephemeral clipboard with a time limit. Paste text or images, share a memorable link, and it auto-expires.",
  },
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
    },
  },
}

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#fafafa" },
    { media: "(prefers-color-scheme: dark)", color: "#09090b" },
  ],
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className={`${geistSans.variable} ${geistMono.variable} antialiased`}>
        <I18nProvider>
          <ThemeProvider>
            {children}
          </ThemeProvider>
        </I18nProvider>
        <GoogleAnalytics gaId={gaId} />
        <ServiceWorkerRegistration />
      </body>
    </html>
  )
}
