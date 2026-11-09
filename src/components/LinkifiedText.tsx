import { useMemo } from "react"
import { linkify } from "@/lib/linkify"

interface LinkifiedTextProps {
  text: string
}

/**
 * Renders plain text, turning any URL it contains into a clickable link that
 * opens in a new tab. Intended to sit inside the existing `<pre>` blocks so
 * whitespace, line breaks and font stay untouched.
 */
export function LinkifiedText({ text }: LinkifiedTextProps) {
  const tokens = useMemo(() => linkify(text), [text])

  return (
    <>
      {tokens.map((token, index) =>
        token.type === "link" ? (
          <a
            key={index}
            href={token.href}
            target="_blank"
            rel="noopener noreferrer"
            title={token.href}
            className="text-primary underline decoration-primary/40 underline-offset-2 transition-colors hover:decoration-primary focus:outline-none focus-visible:ring-2 focus-visible:ring-ring/50 rounded-sm"
          >
            {token.value}
          </a>
        ) : (
          <span key={index}>{token.value}</span>
        )
      )}
    </>
  )
}
