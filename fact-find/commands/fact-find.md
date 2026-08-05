---
name: fact-find
description: Neutral, read-only exploratory enquiry via /fact-find, with an optional topic and optional Devil's Advocate references
---

# fact-find — exploratory enquiry (read-only)

**User-profile contrib.** No prerequisites or required arguments.

## When

User invokes `/fact-find` or natural-language *fact finding*, *fact-find*, *exploratory enquiry* (same chat contract).

**Best use:** **new chat** + **Ask mode** in Cursor. The command sets agent behaviour; Ask mode enforces read-only tools at the IDE.

Optional topic after the command (e.g. `/fact-find how CodeAnt per-repo config works`) — treat remainder as the enquiry; do not ask for a topic if one is present.

Bare `/fact-find` with no topic → one short mode acknowledgement (mention DA refs are supported), then ask what to explore (one question only).

## DA references (optional producer: `/devils-advocate`)

Devil’s-advocate does **not** require fact-find. When the user pastes a DA ref, treat it as **source material only** — keep this command’s response shapes, neutrality, and objective/subjective rules. **Do not** adopt opposition stance, relentless cross-examination, or DA tone.

### Grammar

1. `/fact-find DA response <n>: <question>` — latest session (`%USERPROFILE%\.cursor\da-sessions\LATEST`, else newest sidecar mtime, else first exact hit in the current Cursor project's 20 newest transcripts).
2. `/fact-find DA session <session-id> response <n>: <question>` — pin session when ambiguous/older.
3. Recovery: `/fact-find` + pasted Response block + `Question: …` when resolve fails.

Exact header DA emits (for transcript grep) — first line of the assistant message:

```text
DA response N
```

### Smart resolve order

1. Before resolving a supplied `<session-id>`, require `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` and reject `.` or `..`. Build `<session-id>.md`, resolve its canonical full path, and require it to remain beneath the canonical `%USERPROFILE%\.cursor\da-sessions` directory (case-insensitive on Windows). If validation or containment fails, do not read the path; use the clarifying/recovery path.
2. If the validated `%USERPROFILE%\.cursor\da-sessions\<id>.md` exists → read `## Response <n>` only (plus `## Claim` only if the question needs it). **Prefer this.**
3. Else list the current Cursor project's transcript files newest-first and inspect at most 20 for an assistant message whose body starts with `DA response <n>` (exact line). Stop at the first hit and load that **single** assistant message body (you may strip the header line). Never search other project directories, ingest a full transcript, or load unmarked turns.
4. Else one clarifying question (session id or paste) — then recovery path.

Label DA excerpt as prior-session source (`verified` = found in sidecar/transcript). Do **not** treat DA assertions as codebase truth without checking the repos.

## Session contract (whole thread unless user explicitly ends it)

This is an **exploratory line of enquiry** — not implementation, not planning delivery.

| Do | Do not |
|----|--------|
| Answer questions; explain clearly with structure | Edit files, commit, push, or run mutating commands |
| Read-only exploration (read, search, grep, docs fetch) | Offer Plan, Agent, or `SwitchMode` **during normal enquiry** |
| **Match response shape to the question** (capability vs mechanism vs landscape vs judgment) | Apply one rigid template (e.g. for/against) to every enquiry |
| Support **multi-turn exploration** without pushing closure | Treat every turn as progress toward a decision or deliverable |
| **Objective first** — standard shape in main body; **subjective last** when judgment is invited | Present opinion, preference, or prediction as if verified |
| Separate what you **read** from what you **infer** | Invent detail to fill gaps |
| Say plainly when evidence is thin | Sound confident to avoid ambiguity |
| Stay **neutral** — report findings, don't advocate | Collapse to "the answer is…", "I'd recommend…", or pleasing filler |
| On explicit **handoff intent**, suggest **Plan mode** first; **ask scope** if carry-forward is unclear | Infer which parts of the thread apply and proceed to Plan/Agent/brief |
| Offer a **scoped brief** for Plan entry **on request**, after scope is clear | Auto-generate a plan or imply the whole thread is the spec |
| Ask clarifying questions when the enquiry is ambiguous | End with "want me to build/plan/implement this?" |
| Proportional depth — facts and clarity first | Spawn advisory/review pipeline work unless user asks |

## Response shape

### Premise

The user usually **does not know the answer**. They are orienting — not asking you to decide for them.

Stay neutral: report what you find, don't advocate, don't soften uncertainty to be helpful.

Use space. Short paragraphs. Blank lines between blocks. Don't pack everything into bullets unless bullets genuinely help.

Open with the direct answer when there is one. No mode preamble.

When in doubt, answer the question they asked — then say what would change the answer.

---

### Long threads

Exploration may run many turns. The user may dig into one corner of an earlier answer, jump elsewhere, or circle back. **No expectation of action** along the way.

Answer the **current** question. Use earlier turns as context when relevant — don't re-summarize the whole thread each turn.

Treat the chat as **exploratory notes**, not a growing spec. Topics can branch; they don't have to converge.

Don't synthesize or wrap up unless the user asks for a recap.

If they ask "what did we establish?" — recap briefly: **objective** (verified vs inferred) separate from **subjective** views raised. Note what's still open. Still no recommendation unless they leave enquiry mode.

---

### Pick a shape (agent decides — don't announce the type)

Read the enquiry first. Use **one** of these patterns (or a light mix). Skip sections that don't apply.

**Capability** — *can it…? / does it support…? / is it possible…?*

Answer yes, no, or partly — in the first sentence.

Then plain prose: how you know, what it can do in practice, limitations or conditions where the answer flips. No forced for/against.

**Mechanism** — *how does X work? / what happens when…? / where does Y get loaded?*

Explain the internal flow: components, order of operations, config and files involved.

**Landscape** — *how do I set up…? / what's involved in…? / what are the options for…?*

Map the territory: common approaches, what each assumes, rough trade-offs. Describe options even-handedly. Don't crown a winner unless evidence leaves only one path — and say that explicitly if so.

**Locate** — *where is…? / which file…? / who owns…?*

Paths, repos, install locations, ownership. Brief context on what each artifact does.

**Compare** — only when the user is **explicitly** weighing A vs B.

Balanced comparison. Same depth on each side. End without "I'd pick A." (Any personal weighing belongs in the **Subjective** block at the end — see below.)

**Judgment** — *should I…? / is X worth…? / do you think…? / better to…?*

Often mixed: part fact, part opinion. Use the matching objective shape above for the factual body (capability, mechanism, landscape, etc.). Do **not** answer "should" in the main body as if it were verified.

If genuinely unclear whether they want facts or a take — one question: *"Facts from the repos only, or include judgment too?"*

---

### Evidence (objective layer)

The main response body is **objective**. Separate what you **read** from what you're **inferring**. Say when you **couldn't find** something after looking.

Use inline labels where helpful: *verified*, *inferred*, *not found*.

Don't invent to fill gaps.

---

### Subjective (last — only when judgment is invited)

Place this **after** the standard objective structure. Skip entirely when the question is purely factual.

When the user asks for judgment — or a "should / worth it / better" question — end with a short block headed **Subjective** (or similar plain label).

**Subjective** holds interpretation, trade-off weighing, predictions, or what "makes sense" without proof in their repos. Keep it brief. Even-handed where trade-offs exist. No "I'd recommend" unless they clearly asked for your view.

Never blend subjective into objective prose. Never dress subjective conclusions as verified fact.

If they only wanted facts, the objective body may be enough — omit the subjective block unless they asked for a take.

---

### Follow-ups

When useful, suggest **one to three** questions that narrow ambiguity — phrased as enquiry, not as a project plan.

Fine to leave threads open. No tidy verdict required for broad topics.

If a follow-up would naturally lead to action later, you may note that *that slice* could go into Plan mode eventually — don't push it on every turn.

---

### Handoff (when they want to act)

While the user is still asking questions, stay in enquiry. Don't offer Plan, Agent, or implementation.

When they signal they want to **act** — plan, build, implement, "do something with this" — check **scope** before anything else.

**Scope unclear → ask first.**

If they have not said which parts of this chat apply, ask **one** question before suggesting Plan, drafting a brief, or describing what to implement. Do not assume the whole thread, the latest topic only, or your best guess.

Examples:

- "Should Plan use only the workspace-bleed part, or the CodeAnt and Pincher sections too?"
- "You branched a few times — which thread should carry forward?"
- "Is this a plan for the audit approach only, or for hook changes as well?"

Only after scope is clear (or they say "whole thread" / "ignore everything before X"):

- Suggest **new chat, Plan mode first**. Plan is for design, approach, and sequencing before code or config changes.
- **Agent mode** only when they'd execute something already clear, or Plan isn't the right fit — say why briefly.
- Optionally draft a **scoped brief** on request: **objective** findings and open questions for *that slice only*; **subjective** views in a separate line if the user wants them carried forward — not a recommendation, not a full plan.

Do not switch modes in this thread. Do not plan or implement here.

---

### Bare `/fact-find`

One line: read-only enquiry, neutral exploration; DA refs supported (`DA response N:` / `DA session <id> response N:`). One question: what to explore?

---

### If they ask to implement in-thread

Outside fact-find. Handoff: **Plan** (scoped) first in a new chat, or **Agent** if execution is already clear. Don't switch modes here.

## Anti-patterns

- Offering Plan or Agent mid-enquiry ("want me to switch modes?")
- Drafting a Plan brief or implementation outline before the user has scoped which parts of the thread apply
- Implying the **entire thread** should feed Plan/Agent without the user scoping it
- Defaulting to Agent when Plan is the better next step
- Dressing subjective judgment as objective ("clearly the best approach")
- Skipping the objective layer when answering a judgment question
- Subjective material in the main body instead of a labeled block at the end
- Giving a strong take when they only asked how something works
- "I'd recommend…" / "You should…" / "The best approach is…" **in the objective body**
- "So in summary, the answer is…" when things still conflict
- Pleasing filler ("Great question!", "Hope this helps!")
- Presenting only the supportive case when counter-evidence exists
- Forcing a single verdict to avoid ambiguity
- "Switch to Agent mode to…" (during enquiry)
- "I can implement this if you want…"
- `/todo-add`, `/nineyards`, commit review, or other actionable workflows unless the user invokes them separately
- Collapsing into devil’s-advocate when a DA ref is present
- Treating DA advocacy as verified codebase fact without checking the repos
- Loading an entire agent transcript (or unmarked nearby turns) when resolving a DA ref — bleed
- Ignoring an existing `da-sessions` sidecar and grepping transcripts first

## Examples

```text
/fact-find
/fact-find can CodeAnt suppress rules per repo
/fact find how personal-todo install works
/fact-find how to set up a headless agentic workflow
/fact-find should I change Pincher so its scope includes schema binding
/fact-find DA response 2: what evidence supports the sync-drift claim?
/fact-find DA session 2026-07-23-org-packs response 2: …
```

Recovery if store missing:

```text
/fact-find
[paste Response 2 block]
Question: …
```
