const STORAGE_KEY = "shoufa-recent-slugs";
const MAX_RECENT = 10;

export function getRecentSlugs(): string[] {
  if (typeof window === "undefined") return [];
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (!stored) return [];
    const parsed: unknown = JSON.parse(stored);
    return Array.isArray(parsed)
      ? parsed.filter((slug): slug is string => typeof slug === "string").slice(0, MAX_RECENT)
      : [];
  } catch {
    return [];
  }
}

export function addRecentSlug(slug: string): string[] {
  if (typeof window === "undefined") return [];
  const slugs = getRecentSlugs();
  // Remove if already exists, then add to front
  const filtered = slugs.filter((s) => s !== slug);
  const updated = [slug, ...filtered].slice(0, MAX_RECENT);
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(updated));
  } catch {
    // Ignore storage failures; the in-memory list still updates.
  }
  return updated;
}

export function removeRecentSlug(slug: string): string[] {
  if (typeof window === "undefined") return [];
  const slugs = getRecentSlugs();
  const updated = slugs.filter((s) => s !== slug);
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(updated));
  } catch {
    // Ignore storage failures; the in-memory list still updates.
  }
  return updated;
}
