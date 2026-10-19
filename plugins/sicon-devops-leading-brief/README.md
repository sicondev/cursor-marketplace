# Sicon Devops Leading Brief

Devops Leading Brief — ADO card context via /DLB; fat chat + thin brief file; implement inline by default (Superpowers only when pinned); ship offer with nineyards-shaped message gate; fullmonty = implement + autoland ship + pr-clearance

Install from the Sicon Team Marketplace, then use `/DLB` in chat.

## What lives where

| Concern | Source of truth (contrib) | Installed runtime path |
|---------|---------------------------|------------------------|
| `/DLB` slash | `adapters/cursor/commands/DLB.md` | Plugin `sicon-devops-leading-brief` (or profile `commands/DLB.md`) |
| DLB skill body | `adapters/cursor/skills/devops-leading-brief/SKILL.md` | **Plugin-first:** `plugins\sicon-devops-leading-brief\…` or newest under **`plugins\marketplaces\`** / **`plugins\cache\`**; dogfood `%USERPROFILE%\.cursor\skills\devops-leading-brief\SKILL.md` only if no plugin |
| Trigger rule | `adapters/cursor/rules/dlb-triggers.mdc` | Plugin or profile `rules/dlb-triggers.mdc` |
| Pack README | `content/README.md` | Plugin content or dogfood `%USERPROFILE%\.cursor\packs\devops-leading-brief\README.md` |

This pack’s `content/` is README-only; adapters carry the Cursor surfaces. Prefer Team Marketplace plugin `sicon-devops-leading-brief` over packs dogfood.

## Commands

| Command | Purpose |
|---------|---------|
| `/DLB <id>` | Brief — findings + Enrich; write thin brief file; stop |
| `/DLB <id> implement` | Implement — **inline** (Superpowers only if pinned); ship offer by default |
| `/DLB <id> fullmonty` | Implement + ship **autoland** (no Enrich stop / ship offer / message gate) + `/pr-clearance` **to quiet** when available (else warn + skip); product decisions early; disregard security broaden |

**Prove / Fix-in:** new unit-test *files* only when card **Fix in** is **270** (mainline). Fix-in **260** (and other non-270) → build + existing splash tests only. Cherry to another version → product paths by default (omit `*Tests*`, `*.test.*` / `*.spec.*`, `__tests__/**`, and project-file churn unless Join).

## Make implementers engage my skills / Tasks

DLB (and other implementers such as autonomous-dev) do **not** hardcode product agents. The write-root catalog is **shared**: .cursor/agent-implementation-toolkit.json. Two tiers:

### Skills (always via write-root catalog)

1. Install DLB (plugin).
2. Add `{writeRoot}/.cursor/agent-implementation-toolkit.json` with `engage: read` rows.
3. Done — when `when.globs` hit brief Paths, DLB **Reads** those skills/docs. **No** profile allowlist.

### Tasks (catalog + profile allowlist)

Unattended `/DLB` / fullmonty can spawn Tasks **only** when you opt in on your machine:

1. Same catalog with `engage: task` + `agent` (agent definition must already exist under the write root).
2. Create `%USERPROFILE%\.cursor\agent-implementation-toolkit-allowlist.json` listing agent names you trust to auto-spawn:

```json
{ "agents": ["foreman", "devexpress-data-shape-review", "devex-guru"] }
```

3. A product PR **cannot** enlarge this list — only your profile can. Missing allowlist → skills/`read` still work; **no** Task spawn from the catalog.

| `engage` | Needs toolkit row | Needs profile allowlist | Behaviour |
|----------|-------------------|-------------------------|-----------|
| `read` | yes | **no** | Read path-allowlisted files under `.cursor/skills\|agents\|rules/`, `devtools/org/`, `docs/` |
| `task` | yes | **yes** | After product decisions + branch: spawn Task if allowlisted **and** on-disk agent exists |

**You do not need to change the skill/agent itself** for discovery. Keep normal `SKILL.md` / agent definitions; point the catalog at them; add Task names to your profile allowlist only if you want auto-spawn.

Minimal catalog examples:

```json
{
  "version": 1,
  "entries": [
    {
      "id": "new-document-type",
      "kind": "convention",
      "engage": "read",
      "paths": [".cursor/skills/new-document-type/SKILL.md"],
      "when": { "globs": ["**/DocumentTypes/**", "**/*DocumentType*.cs"] },
      "required": false
    },
    {
      "id": "stack-builder",
      "kind": "build",
      "engage": "task",
      "agent": "foreman",
      "when": { "globs": ["**/API/Controllers/**", "**/Repositories/**"] },
      "required": false
    }
  ]
}
```

Notes:

- Same catalog shape works in Approvals, Hub, Manufacturing, Platform — only the rows differ.
- Do **not** list PreCursor/Mobius (or other disabled gates) unless you want them engaged.
- DLB does **not** auto-create the catalog or the profile allowlist on first engage. Copy from this README when you opt in.
- Residual risk: allowlist is by **name**; a later PR can change that agent’s body — treat write-root agent PRs as trusted once you allowlisted the name.
- Full field rules live in the skill § **Repo toolkit load**.

## Reliability

Supported contract: `/DLB` + skill + triggers. ADO/Halo quality and ship-chain success remain agent- and environment-dependent.

## Reason for existing

Packages ADO leading-brief as its own contrib so teams can brief and implement in-agent with a durable thin brief file and a gated ship chain (or fullmonty autoland when requested).

## Other contribs

- **Available packs** — `contrib/README.md` in ai-devtools
- **Installed packs** — `%USERPROFILE%\.cursor\tooling.lock.json`

## Attribution

Author / Maintainer: Rudolf Bothma `<rudolf.bothma@sicon.co.uk>`
