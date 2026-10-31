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
