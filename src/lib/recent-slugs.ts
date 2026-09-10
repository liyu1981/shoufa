const STORAGE_KEY = "shoufa-recent-slugs";
const MAX_RECENT = 10;

export function getRecentSlugs(): string[] {
  if (typeof window === "undefined") return [];
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    return stored ? JSON.parse(stored) : [];
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
  localStorage.setItem(STORAGE_KEY, JSON.stringify(updated));
  return updated;
}

export function removeRecentSlug(slug: string): string[] {
  if (typeof window === "undefined") return [];
  const slugs = getRecentSlugs();
  const updated = slugs.filter((s) => s !== slug);
  localStorage.setItem(STORAGE_KEY, JSON.stringify(updated));
  return updated;
}
