<!-- contrib-managed: fact-find@0.1.0 — source: ai-devtools/contrib/fact-find/ — prefer PR there; local edits may be overwritten on sync -->

# Fact-find — exploratory enquiry

Fact-find is a small, user-scoped contrib for neutral, read-only exploration. It has no pack prerequisites and requires no command arguments.

## Install

From an `ai-devtools` checkout:

```powershell
.\bootstrap\Install-UserPack.ps1 -Pack fact-find
```

Reload Cursor after installation. No product-repository files are changed.

Uninstall:

```powershell
.\bootstrap\Uninstall-UserPack.ps1 -Pack fact-find
```

## Usage

Use a new chat in Ask mode when possible:

```text
/fact-find
/fact-find can CodeAnt suppress rules per repo
/fact-find how personal-todo install works
/fact-find should I change Pincher so its scope includes schema binding
```

Bare `/fact-find` acknowledges the enquiry mode and asks what to explore. Text following the command is treated as the topic immediately.

Fact-find keeps the thread exploratory rather than turning it into implementation or delivery planning. It separates verified evidence from inference, stays neutral, and labels subjective judgment when the question invites it.

## Optional Devil's Advocate references

Fact-find can inspect a response produced by the `devils-advocate` contrib when the user supplies a reference:

```text
/fact-find DA response 2: what evidence supports the sync-drift claim?
/fact-find DA session 2026-07-23-org-packs response 2: what changed?
```

`devils-advocate` is optional. Fact-find works normally without it and does not declare it as a prerequisite.

## Reliability

The supported install contract is the `/fact-find` slash command with either no arguments or an optional topic. Ask-mode enforcement, neutrality, response depth, and optional DA-reference resolution remain agent-dependent.
