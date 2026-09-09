<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

# Git Workflow Convention

When committing work or producing a commit message, follow these rules.

## Commit Message Format

Every commit uses **conventional-commit style**:

```
<type>(<scope>): <summary>

<body with detailed bullets>
```

### Types
`feat`, `fix`, `style`, `chore`, `refactor`, `docs`, `build`, `test`, `perf`, `revert`

### Scopes
`api`, `ui`, `store`, `slugs`, `components`, `config`, `styles`

### Rules
- Title: lowercase type/scope, imperative, under ~50 chars
- Body: bulleted list of what changed and why
- For `fix` commits: include **problem cause** + **fix solution**
- End with verification: "Verified: pnpm lint, pnpm build"

## "generate git msg" Workflow

When asked to generate a commit message:
1. **Never run `git commit`** — only print the message
2. Base on: `git diff`, `git status`, `git log --oneline -10`
3. Print full message (title + body) for the user to commit

## Commit Hygiene

- **Only commit when explicitly asked**
- Inspect before committing: `git status`, `git diff`, `git log --oneline -10`
- Stage only intended files
- **Never commit secrets** (API keys, private keys, credentials)
- On failed commit, fix and make a **new** commit (don't amend)
- Keep history linear, no force-push
