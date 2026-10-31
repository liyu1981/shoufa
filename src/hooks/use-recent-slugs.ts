import { useState, useCallback } from "react";
import {
  getRecentSlugs,
  addRecentSlug,
  removeRecentSlug,
} from "@/lib/recent-slugs";

export function useRecentSlugs() {
  const [recentSlugs, setRecentSlugs] = useState<string[]>(getRecentSlugs);

  const addSlug = useCallback((slug: string) => {
    const updated = addRecentSlug(slug);
    setRecentSlugs(updated);
  }, []);

  const removeSlug = useCallback((slug: string) => {
    const updated = removeRecentSlug(slug);
    setRecentSlugs(updated);
  }, []);

  return { recentSlugs, addSlug, removeSlug };
}
