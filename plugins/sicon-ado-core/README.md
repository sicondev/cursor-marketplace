# Sicon ADO Core

Shared Azure DevOps Git, pull-request, work-item, and build library for other Sicon plugins. There is no slash command.

Install from the Sicon Team Marketplace, then enable the plugin.

## Scope

ADO Core owns generic operations:

- Resolve on-premises ADO endpoints from `remote.origin.url`
- Query, resolve, and create pull requests
- Post general PR discussion threads (`New-AdoCorePullRequestThread`)
- List PR discussion threads, reply without changing status, and set thread status
- Add or update a PR reviewer (`Set-AdoCorePullRequestReviewer -ReviewType Required|Optional`, default Required)
- Build PR web URLs
- Resolve authenticated-user metadata
- Get work items and comments
- Batch-get work items and get work-item revisions
- Create and update work items (`New-AdoCoreWorkItem` / `Update-AdoCoreWorkItem`)
- Link work items to pull requests; optionally commits via `-LinkCommits`
- Attach files to work items
- Resolve build definitions and list builds
- Escape and execute Wiql queries

It does not own Flyby lifecycle behavior, Nineyards message gating, branch selection, card wording, Approvals board policy, or agent commands.

## Usage

Other Sicon workflows load this library. There is no `/ado-core` command — do not run this plugin from chat. Dot-source and call helpers; do not read the full script into the agent context.
