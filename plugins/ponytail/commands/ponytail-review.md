---
name: ponytail-review
description: Review the current changes for over-engineering only, and list what to cut.
---

# /ponytail-review

Read and follow `skills/ponytail-review/SKILL.md` in this plugin in full.

Review the current code changes for over-engineering only, not correctness. One line per finding: `L<line>: <tag> <what to cut>. <replacement>.` Tags: delete (dead code or speculative feature), stdlib (reinvented standard library), native (dependency doing what the platform does), yagni (abstraction with one implementation), shrink (same logic, fewer lines). End with the net lines removable. If nothing to cut: `Lean already. Ship.`
