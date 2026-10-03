# Ponytail

Lazy senior dev mode. Forces the simplest, shortest solution that actually works: YAGNI, stdlib first, no unrequested abstractions.

Install from the Sicon Team Marketplace, then reload Cursor. The always-on rule applies in every chat. Slash commands and skills cover intensity changes and the one-shot reports.

## Commands

| Command | Purpose |
|---------|---------|
| `/ponytail` | Intensity: lite, full (default), ultra, or off |
| `/ponytail-review` | Over-engineering review of the current changes |
| `/ponytail-audit` | Whole-repo over-engineering audit |
| `/ponytail-debt` | Harvest `ponytail:` shortcut comments into a ledger |
| `/ponytail-gain` | Published benchmark scoreboard |
| `/ponytail-help` | Quick reference |

## What is packaged

| Piece | Source |
|-------|--------|
| Always-on rule | Upstream `.cursor/rules/ponytail.mdc` (`alwaysApply: true`) |
| Skills | Upstream `skills/ponytail`, `ponytail-review`, `ponytail-audit`, `ponytail-debt`, `ponytail-gain`, `ponytail-help` |
| Slash commands | Cursor command adapters for the six upstream commands |
| Logo | Upstream `assets/logo-dark.svg`, on a `#111111` plate so the white mark stays visible |
| License | Upstream MIT |

Node lifecycle hooks are not included. Upstream documents the always-on rule and the Cursor hooks (`sessionStart`, `beforeSubmitPrompt`) as alternatives: a hook cannot remove a rule from context, so `lite`, `ultra`, and `off` cannot win against this rule. This package keeps the rule.

## Source

| | |
|--|--|
| Upstream | [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail) |
| Fork used for this package | [sicondev/ponytail](https://github.com/sicondev/ponytail) |
| Version | 4.10.0 |
| Commit | `e3ba2aa6f1e6f0bc4d69eb09c9f0d0a93af56156` (`chore: release v4.10.0`) |

The fork has no `v4.10.0` git tag. The release commit is the pin. Author of the plugin content is Dietrich Gebert. Sicon publishes it on the Team Marketplace.

## Try it locally

Copy this folder to the Cursor local plugins directory, then reload Cursor and open Customize. Ponytail should list the always-on rule, six skills, and the six slash commands.

- macOS / Linux: `~/.cursor/plugins/local/ponytail`
- Windows: `%USERPROFILE%\.cursor\plugins\local\ponytail`

```bash
rm -rf ~/.cursor/plugins/local/ponytail
cp -a plugins/ponytail ~/.cursor/plugins/local/ponytail
```

## Attribution

Upstream author: Dietrich Gebert — <https://github.com/DietrichGebert>

Copyright (c) 2026 DietrichGebert. MIT License. See `LICENSE`.
