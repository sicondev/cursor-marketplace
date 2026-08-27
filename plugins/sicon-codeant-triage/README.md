# Sicon CodeAnt Triage

Triage CodeAnt comments on Azure DevOps pull requests, and scan for anti-patterns you have saved locally.

Install from the Sicon Team Marketplace, then use the commands below in chat.

## What it stores locally

User anti-pattern rows (UAPs) and promote preferences live in your Cursor profile, **not** in this plugin folder and **not** in product git repos:

`%USERPROFILE%\.cursor\codeant-triage\` (`anti-patterns.user.md`, `promote-preferences.json`)

Optional profile rules: `%USERPROFILE%\.cursor\rules\codeant-uap-*.mdc`

Run the pack’s init script from the plugin `scripts/` folder if the user catalog is missing. Core CAP/AP rows ship with the plugin (`content/anti-patterns.core.md`).

## Commands

| Command | Purpose |
|---------|---------|
| `/codeant-triage` | Work through CodeAnt findings on a PR — fix, skip, or save as a personal anti-pattern |
| `/codeant-triage <PR#>` | Fetch findings for that PR, then the same loop |
| `/codeant-triage-uapscan` | Scan uncommitted files for those anti-patterns (no commit or PR reply) |
| `/codeant-triage-uapscan-deepscan` | Scan the workspace or a folder (narrow the path if the scan is large) |

Requires Windows integrated auth to on-prem Azure DevOps and a TFS-shaped `remote.origin.url`.
