export type LinkToken =
  | { type: "text"; value: string }
  | { type: "link"; value: string; href: string }

/**
 * Matches absolute http(s) URLs and bare `www.` hosts. The character class
 * keeps trailing punctuation out of the cheap match; the exact end is decided
 * by `trimTrailingPunctuation` so balanced brackets inside paths survive.
 */
const URL_PATTERN = /(?:https?:\/\/|www\.)[^\s<>"'`]+/gi

const TRAILING_PUNCTUATION = /[.,;:!?'"]/

const BRACKETS: Record<string, string> = { ")": "(", "]": "[", "}": "{" }

/**
 * Drops punctuation that is almost certainly sentence punctuation rather than
 * part of the URL, e.g. `see https://example.com.` or `(https://example.com)`.
 * A closing bracket is only dropped when it has no matching opening bracket
 * inside the URL, so `https://en.wikipedia.org/wiki/Foo_(bar)` stays intact.
 */
function trimTrailingPunctuation(url: string): string {
  let result = url

  for (;;) {
    const last = result.at(-1)
    if (!last) return result

    if (TRAILING_PUNCTUATION.test(last)) {
      result = result.slice(0, -1)
      continue
    }

    const opening = BRACKETS[last]
    if (opening) {
      const opens = result.split(opening).length - 1
      const closes = result.split(last).length - 1
      if (closes > opens) {
        result = result.slice(0, -1)
        continue
      }
    }

    return result
  }
}

/** Rejects leftovers like `www.` or `https://` that cannot be navigated to. */
function isValidUrl(url: string): boolean {
  const withoutScheme = url.replace(/^https?:\/\//i, "")
  return withoutScheme.replace(/^www\./i, "").length > 0
}

function toHref(url: string): string {
  return /^https?:\/\//i.test(url) ? url : `https://${url}`
}

/**
 * Splits plain text into text and link tokens so URLs pasted into a space can
 * be rendered as clickable anchors.
 */
export function linkify(text: string): LinkToken[] {
  const tokens: LinkToken[] = []
  let lastIndex = 0

  for (const match of text.matchAll(URL_PATTERN)) {
    const start = match.index ?? 0
    const raw = match[0]
    const url = trimTrailingPunctuation(raw)

    if (!isValidUrl(url)) continue

    if (start > lastIndex) {
      tokens.push({ type: "text", value: text.slice(lastIndex, start) })
    }

    tokens.push({ type: "link", value: url, href: toHref(url) })
    lastIndex = start + url.length
  }

  if (lastIndex < text.length) {
    tokens.push({ type: "text", value: text.slice(lastIndex) })
  }

  return tokens
}
