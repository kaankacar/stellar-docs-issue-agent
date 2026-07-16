# stellar-docs issue agent

An AI agent that triages new issues on a docs repo and, when an issue is a small, well-scoped,
low-risk fix, **drafts the fix itself and opens a PR** — no Copilot hand-off, no user-token PAT
needed. Built for `stellar/stellar-docs`; repo-agnostic (reads `${{ github.repository }}`).

Companion to the [PR review bot](https://github.com/kaankacar/stellar-docs-review-bot) — one
handles incoming PRs, this one handles incoming issues (and turns the easy ones into PRs that
the PR bot then reviews).

## How it works — one workflow, two jobs (the safety boundary)

`issue-agent.yml` runs on every opened/reopened issue, split into two jobs on purpose:

- **`triage`** — runs the model (Claude), reads the issue, dedupes (open + closed issues, and
  open PRs that might resolve it), verifies the claim against the checkout, labels + prioritizes,
  proposes a close where policy allows, and **judges auto-fixability**. It proposes an auto-fix
  via a label; it has no write power. This is the half that ingests untrusted issue text.
- **`autofix`** — runs only for issues labeled `triage:autofix-candidate`. Our own agent
  creates a branch, makes the minimal edit, and opens a PR (as the bot identity) for review. It
  **never merges**. Runs fully in CI on the App (or `GITHUB_TOKEN`) — **no PAT** — because
  opening a PR only needs `contents: write`, not a user token.

The PR it opens is then picked up by the [PR review bot](https://github.com/kaankacar/stellar-docs-review-bot),
closing the loop: **issue → drafted fix PR → review → (trivial ones) auto-merge**, all under
one bot identity, no human in the middle for the easy cases.

## The auto-fix bar

`triage` applies `triage:autofix-candidate` **only if all** hold:

- the change is small and touches one or a few files;
- the correct outcome is unambiguous — a typo, wording, broken link/anchor, an obvious factual
  correction, or a clearly-specified small addition;
- it is **not** an opinionated rewrite, a multi-file restructure, new content needing
  product/design judgment, or anything security-relevant.

Everything else is triaged and labeled for a human. A rewrite like "restructure the whole JS
SDK section" is deliberately *not* auto-fixed — it needs a person to scope it. And every
auto-fix lands as a PR that is reviewed before merge — the fix agent can't merge its own work.

## Bot identity — one branded bot instead of github-actions[bot] (optional)

By default triage/fix actions post as **github-actions[bot]**. To have this agent (and the
companion PR bot) act as a single branded **GitHub App** identity like `stellar-docs-bot[bot]`,
run the included one-command setup — two browser clicks total (Create, then Install):

```bash
./setup-github-app.sh   # see SETUP.md
```

It registers the app via GitHub's manifest flow, captures the App ID + private key
automatically (nothing to copy/paste), and sets them as the `APP_ID` / `APP_PRIVATE_KEY` repo
secrets. Each job mints a short-lived installation token with `actions/create-github-app-token@v3`,
scoped down per job. If the secrets are absent the workflow falls back to `GITHUB_TOKEN`.

## Alternative: hand off to the Copilot coding agent

Instead of fixing it ourselves, `autofix` can assign the issue to the **GitHub Copilot coding
agent** (which opens its own draft PR). We chose self-fix as the default because it needs no
extra credential; the Copilot path requires a **user-token PAT** (`ISSUE_AGENT_PAT` with
`issues: write`) — the default Actions `GITHUB_TOKEN` and even GitHub App installation tokens
are server-to-server and **cannot** assign Copilot (GitHub omits `copilot-swe-agent` from their
`suggestedActors`; verified empirically). If you prefer that route, set `ISSUE_AGENT_PAT` and
swap the `autofix` job for the Copilot-assignment variant (kept in git history).

## Guardrails (recommended for production)

Auto-fix opens PRs automatically, so bound it:

- Keep the strict auto-fix bar above (small + unambiguous + low-risk only).
- Every fix is a PR reviewed by the PR bot + humans before merge — nothing auto-fixes to main.
- Add a human gate for anything nontrivial: have `triage` propose `triage:autofix-candidate`
  and require a maintainer's `triage:approve-autofix` before `autofix` runs.
- Consider running `autofix` on a schedule/batch rather than per-issue, so a burst of issues
  (or an agent dropping a dozen at once) can't trigger a swarm of PRs.

## Install

1. Copy `.github/workflows/issue-agent.yml` and `.github/triage-policy.md` into your repo.
2. Create the labels the policy uses (`P1`, `P2`, `triage:*`, `triage:autofix-candidate`).
3. Set `CLAUDE_CODE_OAUTH_TOKEN` (or swap to an org `ANTHROPIC_API_KEY`).
4. Optional: `REPO=owner/name ./setup-github-app.sh` for the branded bot identity (see
   [SETUP.md](SETUP.md)); skip it and the bot posts as `github-actions[bot]`.
5. Open a small, well-scoped issue and watch it get triaged — and, if it clears the bar, turned
   into a drafted-fix PR the PR bot reviews.

## The rulebook

Shared with the PR bot: [`.github/triage-policy.md`](.github/triage-policy.md) is the single
source of truth both agents read at runtime. Change policy via PR; no code change needed.
