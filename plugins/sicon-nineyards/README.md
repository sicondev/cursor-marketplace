# Sicon Nineyards

Commit, push, and create or update a pull request through one message-gated /nineyards workflow

Install from the Sicon Team Marketplace, then use `/nineyards` in chat.

## Usage

```text
/nineyards
/nineyards 19224
/nineyards into 260/dev
/nineyards hub "fix Companies nav permission"
/nineyards kick codeant
```

Nineyards resolves the repository, source branch, target branch, and available repository tooling. It then shows the proposed commit and PR messages and stops. Reply with edits to refine the messages, or say `go` to commit, push, and create or update the PR.

A work-item ID is optional. When supplied, Nineyards includes it in the commit and links it to the ADO pull request. It never prompts for a missing work item.

On **new PR create** (ADO), Nineyards does **not** post `@codeant-ai: review` by default — CodeAnt usually auto-starts. Opt in with `kick codeant` / `request review` at the message gate. Push-to-existing does **not** post. Active leftover trigger threads can block ADO autocomplete — clear them with `/codeant-triage` finalize **resolve** / **reply-only** (not nineyards).

## Repository support

- Repository-local commit and review rules remain responsible for product-specific gates.
- ADO repositories use the installed Nineyards scripts with shared ADO Core and Git Core libraries (plugin-prefer).
- GitHub repositories use Git Core push helpers and the authenticated GitHub CLI (no CodeAnt kick).
- Ship push uses `Push-GitCore -SetUpstream` (not a local `git push -u` wrapper). Existing open PRs are updated with that push; otherwise a new PR is created.

## Verification

Probe a repository without making changes:

```powershell
& "$env:USERPROFILE\.cursor\packs\nineyards\scripts\Get-NineyardsRepoCapabilities.ps1" `
  -RepoRoot C:\Repos\<product> -Json
```

Then invoke `/nineyards` in a dirty repository and confirm that it stops at the message gate before any commit, push, or PR creation.
