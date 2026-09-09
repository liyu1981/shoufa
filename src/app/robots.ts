import type { MetadataRoute } from "next"

export default function robots(): MetadataRoute.Robots {
  const siteUrl = process.env.NEXT_PUBLIC_SITE_URL || "https://shoufa.vercel.app"

  return {
    rules: [
      {
        userAgent: "*",
        allow: "/",
        // Individual spaces are ephemeral and user-generated — don't index them
        disallow: ["/s/", "/api/"],
      },
    ],
    sitemap: `${siteUrl}/sitemap.xml`,
  }
}
