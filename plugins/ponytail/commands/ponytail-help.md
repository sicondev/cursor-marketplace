---
name: ponytail-help
description: Show the ponytail quick reference for levels, skills, and commands.
---

# /ponytail-help

Read and follow `skills/ponytail-help/SKILL.md` in this plugin in full.

Show the ponytail quick reference. One shot, change nothing: do not switch mode, write flag files, or persist anything.

Levels: lite (build what was asked, name the lazier alternative in one line), full (the default ladder: YAGNI, then stdlib, then native, then one line, then minimum), ultra (deletion before addition, challenge the requirement before building).

Commands in this plugin: review (over-engineering review of the current changes), audit (whole-repo over-engineering audit), debt (harvest `ponytail:` comments into a tracked ledger), gain (measured-impact scoreboard from the benchmark), help (this card).

Deactivate with "stop ponytail", "normal mode", or off. Resume anytime. Default mode is full. Upstream can change the default with the `PONYTAIL_DEFAULT_MODE` environment variable (`off`, `lite`, `full`, `ultra`) or a config file at `~/.config/ponytail/config.json` (Windows: `%APPDATA%\ponytail\config.json`) with `{ "defaultMode": "lite" }`. Resolution order: env var, then config file, then full. This marketplace package does not install the Node hooks that read that config; the always-on rule stays on, and intensity changes are instructions to the agent.
