# Sicon PR Clearance

Drive an Azure DevOps pull request to review-quiet: apply Policy, ask only when needed, and complete findings through the configured review tools.

Install from the Sicon Team Marketplace, then use `/pr-clearance` in chat.

## Commands

| Command | Purpose |
|---------|---------|
| `/pr-clearance <pr>` | Clear review findings on that Azure DevOps pull request |
| `/pr-clearance` | Ask for the PR number, then the same loop |

The pull request must already exist. This plugin does not merge or create pull requests.

## Ports

Clearance talks to five **ports** (`review`, `findings`, `forge`, `vcs`, `specialist`), not to a vendor by name. Bind-config maps each port to a tool id. v1 is locked to `codeant-triage`, `codeant-triage`, `ado-core`, `git-core`, and `codeant-triage`. The `specialist` is one worker per Act and one Path per call (serial Paths; dispose at Act end). The roadmap is any installed tool that implements the same calls.

The Ports section above is the consumer contract. Bind-config ships as `content/bind-config.json`.

## Reliability

The supported usage contract is the `/pr-clearance` slash command with a PR number (or a prompt for one). Policy quality, implemented fixes, live review-tool latency, and clickable question cards depend on the agent and host.
