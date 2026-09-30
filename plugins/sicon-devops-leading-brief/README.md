# Sicon Devops Leading Brief

Devops Leading Brief — ADO card context via /DLB; fat chat + thin brief file; implement inline or Superpowers; ship offer with nineyards-shaped message gate

Install from the Sicon Team Marketplace, then use `/DLB` in chat.

## What lives where

| Concern | Source of truth (contrib) | Installed runtime path |
|---------|---------------------------|------------------------|
| `/DLB` slash | `adapters/cursor/commands/DLB.md` | `%USERPROFILE%\.cursor\commands\DLB.md` |
| DLB skill body | `adapters/cursor/skills/devops-leading-brief/SKILL.md` | `%USERPROFILE%\.cursor\skills\devops-leading-brief\SKILL.md` |
| Trigger rule | `adapters/cursor/rules/dlb-triggers.mdc` | `%USERPROFILE%\.cursor\rules\dlb-triggers.mdc` |
| Pack README | `content/README.md` | `%USERPROFILE%\.cursor\packs\devops-leading-brief\README.md` |

This pack’s `content/` is README-only; adapters carry the Cursor surfaces.

## Commands

| Command | Purpose |
|---------|---------|
| `/DLB <id>` | Brief — findings + Enrich; write thin brief file; stop |
| `/DLB <id> implement` | Implement — infer inline vs Superpowers; ship offer by default |

## Reliability

Supported contract: `/DLB` + skill + triggers. ADO/Halo quality and ship-chain success remain agent- and environment-dependent.

## Reason for existing

Packages ADO leading-brief as its own contrib so teams can brief and implement in-agent with a durable thin brief file and a gated ship chain.

## Other contribs

- **Available packs** — `contrib/README.md` in ai-devtools
- **Installed packs** — `%USERPROFILE%\.cursor\tooling.lock.json`

## Attribution

Author / Maintainer: Rudolf Bothma `<rudolf.bothma@sicon.co.uk>`
