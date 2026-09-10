<!-- contrib-managed: pr-clearance@0.2.2 — source: ai-devtools/contrib/pr-clearance/ — prefer PR there; local edits may be overwritten on sync -->

# PR clearance Policy (agent)

Load scripts from the resolved `scripts/` folder (`pr-clearance-lib.ps1`, `pr-clearance-policy.ps1`). This file is the agent table only.

For each finding:

1. `decision = Get-PrClearancePolicyDecision -Finding -Register [-ChangedPaths]` (frozen engage list, not a fresh git diff).
2. If `decision.action` is `dismiss` → complete dismissed with `decision.reason`. No implement. No ask.
3. If `continue`: read `Comment` plus current code at `Path` / `Line`. Resolve with `Resolve-PrClearanceFindingPath` under the repo root only. Reject absolute paths and `..`. No catalog read.
4. Return `{ action: pass | ask | already, reason }`.

| When | Action |
|------|--------|
| Already satisfied on the tip | `already` — complete `fixed`; skip implement/Vcs |
| Invalid, everyday-language reason | `dismiss` |
| Preference-only or product-flavour suggestion with no plausible security, exploitation, correctness, or bug risk | `dismiss` — explain why leaving the code unchanged is safe |
| Valid, bounded, low-risk change whose intended result is clear | `pass` — hand to the specialist even if it is trivial or touches a documented convention |
| Conflicting requirements, unclear intended behaviour, material compatibility/scope risk, or evidence that cannot distinguish a safe dismissal from a defect | `ask` |

Product choice alone is not a reason to ask. Classify the consequence:

- If the current code leaves no plausible security, exploitation, correctness, or bug risk and the suggestion is only a preference, flavour, or documentation convention, dismiss it automatically.
- If the finding is valid and the fix is bounded and low-risk, pass it for implementation instead of asking the human to approve an obvious change.
- Ask only when a human decision materially changes behaviour or risk. The reason must name that unresolved consequence, not merely call it a product choice.

Do not return `fix`. `pass` means hand to the specialist. The coordinator never implements.
