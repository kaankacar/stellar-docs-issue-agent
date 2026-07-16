# stellar-docs issue agent

An AI agent that triages new issues on a docs repo and, when an issue is a small, well-scoped,
low-risk fix, hands it to the **GitHub Copilot coding agent** to draft a PR automatically.
Built for `stellar/stellar-docs`; repo-agnostic (reads `${{ github.repository }}`).

Companion to the [PR review bot](https://github.com/kaankacar/stellar-docs-review-bot) — one
handles incoming PRs, this one handles incoming issues (and turns the easy ones into PRs).

## How it works — one workflow, two jobs (the safety boundary)

`issue-agent.yml` runs on every opened/reopened issue, split into two jobs on purpose:

- **`triage`** — runs the model (Claude), reads the issue, dedupes (open + closed issues, and
  open PRs that might resolve it), verifies the claim against the checkout, labels + prioritizes,
  proposes a close where policy allows, and **judges auto-fixability**. It proposes an auto-fix
  via a label; it has no assignment power. This is the half that ingests untrusted issue text.
- **`dispatch`** — runs **no model**, never reads the issue prose; if the issue carries
  `triage:autofix-candidate` it assigns the **Copilot coding agent**, which opens a branch +
  draft PR and starts working. Because it acts only on the label, untrusted issue text can't
  trigger a code-generation run on its own.

## The auto-fix bar

`triage` applies `triage:autofix-candidate` **only if all** hold:

- the change is small and touches one or a few files;
- the correct outcome is unambiguous — a typo, wording, broken link/anchor, an obvious factual
  correction, or a clearly-specified small addition;
- it is **not** an opinionated rewrite, a multi-file restructure, new content needing
  product/design judgment, or anything security-relevant.

Everything else is triaged and labeled for a human. A rewrite like "restructure the whole JS
SDK section" is deliberately *not* auto-fixed — it needs a person to scope it.

## Assigning Copilot — the one credential you need

Assigning the Copilot coding agent requires a **user token** (a PAT with `repo` / `issues:write`,
or a GitHub App *user-to-server* token). Server-to-server installation tokens — the default
Actions `GITHUB_TOKEN` **and** tokens minted for a GitHub App by
`actions/create-github-app-token` — cannot assign Copilot: GitHub omits `copilot-swe-agent`
from their `suggestedActors`, so the assignment silently no-ops (verified empirically). That is
why this workflow keeps `ISSUE_AGENT_PAT` for this single call even when the branded app
identity below is configured; without the PAT the hand-off is skipped cleanly.

1. Create a fine-grained PAT with `Issues: read and write` (or classic `repo`).
2. Set it as the repo secret **`ISSUE_AGENT_PAT`**.
3. Enable the Copilot coding agent on the repo (Copilot Pro+/Enterprise). The workflow checks
   `suggestedActors` for `copilot-swe-agent` and skips cleanly if it isn't enabled.

Under the hood it uses the GraphQL assignment API (Dec 2025):

```graphql
mutation($assignableId:ID!, $actorId:ID!) {
  replaceActorsForAssignable(input:{assignableId:$assignableId, actorIds:[$actorId]}) {
    assignable { ... on Issue { number } }
  }
}
```
with header `GraphQL-Features: issues_copilot_assignment_api_support`.

## Abuse / cost guardrails (recommended for production)

Auto-fix fires code-generation runs, so bound it:

- Keep the strict auto-fix bar above (small + unambiguous + low-risk only).
- Add a human gate for anything nontrivial: have `triage` propose `triage:autofix-candidate`
  and require a maintainer's `triage:approve-autofix` before `dispatch` assigns Copilot.
- Consider running `dispatch` on a schedule/batch rather than per-issue, so a burst of issues
  (or an agent dropping a dozen at once) can't trigger a swarm of PRs.

## Bot identity — one branded bot instead of github-actions[bot] (optional)

By default triage comments and labels post as **github-actions[bot]**. To have this agent
(and the companion PR review bot) act as a single branded **GitHub App** identity like
`stellar-docs-bot[bot]`, run the included one-command setup — two browser clicks total
(Create, then Install):

```bash
./setup-github-app.sh   # see SETUP.md
```

It registers the app via GitHub's manifest flow, captures the App ID + private key
automatically (nothing to copy/paste), and sets them as the `APP_ID` / `APP_PRIVATE_KEY`
repo secrets. Each job then mints a short-lived installation token with
`actions/create-github-app-token@v3`, scoped down per job. If the secrets are absent the
workflow falls back to `GITHUB_TOKEN` and behaves exactly as before. The one exception is
the Copilot assignment call above, which stays on `ISSUE_AGENT_PAT` (the hand-off *comment*
still posts as the app).

## Install

1. Copy `.github/workflows/issue-agent.yml` and `.github/triage-policy.md` into your repo.
2. Create the labels the policy uses (`P1`, `P2`, `triage:*`, `triage:autofix-candidate`).
3. Set `CLAUDE_CODE_OAUTH_TOKEN` (or swap to an org `ANTHROPIC_API_KEY`) and `ISSUE_AGENT_PAT`.
4. Optional: `REPO=owner/name ./setup-github-app.sh` for the branded bot identity (see
   [SETUP.md](SETUP.md)); skip it and the bot posts as `github-actions[bot]`.
5. Open a small, well-scoped issue and watch it get triaged — and, if it clears the bar, turned
   into a Copilot draft PR.

## The rulebook

Shared with the PR bot: [`.github/triage-policy.md`](.github/triage-policy.md) is the single
source of truth both agents read at runtime. Change policy via PR; no code change needed.
