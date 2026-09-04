# Sicon ADO Core

Shared Azure DevOps Git, pull-request, and work-item library for other Sicon plugins. There is no slash command.

Install from the Sicon Team Marketplace, then enable the plugin.

## Scope

ADO Core owns generic operations:

- Resolve on-premises ADO endpoints from `remote.origin.url`
- Query, resolve, and create pull requests
- Post general PR discussion threads (`New-AdoCorePullRequestThread`)
- Build PR web URLs
- Resolve authenticated-user metadata
- Link work items to pull requests and commits
- Attach files to work items
- Escape and execute Wiql queries

It does not own Flyby lifecycle behavior, Nineyards message gating, branch selection, card wording, or agent commands.

## Usage

Other Sicon workflows load this library. There is no `/ado-core` command — do not run this plugin from chat.
