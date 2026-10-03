---
name: ponytail-gain
description: Show the published ponytail benchmark scoreboard. One-shot display, edits nothing.
---

# /ponytail-gain

Read and follow `skills/ponytail-gain/SKILL.md` in this plugin in full.

Show the ponytail gain scoreboard. One shot, change nothing: do not switch mode, write flag files, or persist anything. Render the published benchmark medians (5 everyday tasks; models Haiku, Sonnet, Opus; source the upstream `benchmarks/` directory and README) as plain ASCII bars: Lines of code, no-skill 100% vs ponytail 6–20% (down 80–94%); Cost, no-skill 100% vs ponytail 23–53% (down 47–77%); Speed, ponytail 3–6× faster. The bar length shows the measured range, the label carries the exact figure. These are benchmark medians, not this repo. Never print a per-repo savings number: the unbuilt version was never written, so there is no real baseline to subtract from in a live repo. For real per-repo figures, point at the debt ledger and the whole-repo audit. Report only.
