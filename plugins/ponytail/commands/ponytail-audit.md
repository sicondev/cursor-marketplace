---
name: ponytail-audit
description: Audit the whole repo for over-engineering and rank what to delete.
---

# /ponytail-audit

Read and follow `skills/ponytail-audit/SKILL.md` in this plugin in full.

Audit the entire repository for over-engineering only, not correctness. Scan the whole tree, not a diff. One line per finding, ranked biggest cut first: `<tag> <what to cut>. <replacement>. [path].` Tags: delete (dead code or speculative feature), stdlib (reinvented standard library), native (dependency doing what the platform does), yagni (abstraction with one implementation), shrink (same logic, fewer lines). End with the net lines and dependencies removable. If nothing to cut: `Lean already. Ship.`
