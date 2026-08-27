# Sicon CodeAnt Triage

Validate CodeAnt (Azure DevOps) PR comments one finding at a time, and scan for your local user anti-patterns.

Install from the Sicon Team Marketplace, then use `/codeant-triage` in chat. Also: `/codeant-triage-uapscan` and `/codeant-triage-uapscan-deepscan`.

## What it stores locally

User anti-pattern rows (UAPs) and promote preferences live in your Cursor profile, **not** in this plugin folder and **not** in product git repos:

`%USERPROFILE%\.cursor\codeant-triage\` (`anti-patterns.user.md`, `promote-preferences.json`)

Optional profile rules: `%USERPROFILE%\.cursor\rules\codeant-uap-*.mdc`

Run the pack’s init script from the plugin `scripts/` folder if the user catalog is missing. Core CAP/AP rows ship with the plugin (`content/anti-patterns.core.md`).

## Commands

| Command | Purpose |
|---------|---------|
| `/codeant-triage` | PR comment loop (Fix / Won't fix / Skip + UAP Disposition) |
| `/codeant-triage <PR#>` | Fetch findings for that PR, then the same loop |
| `/codeant-triage-uapscan` | Scan git-dirty files for in-scope UAPs (no commit) |
| `/codeant-triage-uapscan-deepscan` | Workspace UAP scan (no commit) |

Requires Windows integrated auth to on-prem Azure DevOps and a TFS-shaped `remote.origin.url`.
