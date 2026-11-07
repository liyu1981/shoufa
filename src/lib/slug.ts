/**
 * Slug rules shared with the server (`isValidSlug` in server/src/api.zig):
 * 2-32 characters of lowercase letters, digits, and single hyphens.
 *
 * Used to decide whether a root-level path such as `/soft-nose` is a space
 * link in shorthand form.
 */
export function isValidSlug(slug: string): boolean {
  if (slug.length < 2 || slug.length > 32) return false
  return /^[a-z0-9]+(-[a-z0-9]+)*$/.test(slug)
}
