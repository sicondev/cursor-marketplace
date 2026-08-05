# Sicon Devils Advocate

Find weaknesses in a claim via sustained opposition — not for agreed resolutions; optional fact-find handoff

Install from the Sicon Team Marketplace, then use `/devils-advocate` in chat.

## Who this is for

Use this when you want to **find weaknesses in a design, architecture choice, or claim** before you commit to it. The agent argues against you and makes you justify your position.

**Do not use this if you want an agreed resolution.** It will not soften into consensus, “both sides,” or a joint redesign. If you need alignment or a plan, use a different mode or command.

## What it does

- You invoke `/devils-advocate` with a claim (or bare — it asks for the claim).
- The agent opposes and cross-examines until **you** end the chat.
- Pure thanks / goodbye get a short courteous reply — not another attack round.
- Tone: debate-society — calm, precise, evidence-based — not sarcastic or theatrical.
- It pushes on weak assumptions and cites codebase or web sources when useful.

Slash-only (no casual NL trigger). It does not switch you to Plan/Agent or start implementing.

## How you use it

Run `/devils-advocate Your claim here`.

### New chat vs mid-session

You **can** invoke `/devils-advocate` in an existing chat. It will use that thread’s context (no clean-chat requirement) and still number opposition replies from `DA response 1` for *this* DA run.

For **better results, prefer a new chat** dedicated to the claim:

- Cleaner opposition spine — less bleed from earlier tooling, planning, or off-topic turns.
- Clearer `DA response N` numbering and session id for later recall.
- Cleaner fact-find handoff: the sidecar / marked replies are less likely to silently depend on pre-DA context that fact-find will **not** load (fact-find only pulls the marked response, not the whole host chat).

Mid-session DA is fine for a quick stress-test where the claim already sits in context. Use a new session when you care about a durable debate log or cross-chat `/fact-find DA response N: …` later.

## What a session looks like

- First real opposition reply: session id stated once.
- Every opposition reply starts with `DA response 1`, `DA response 2`, …
- **Agent** (writable): may save a DA-only sidecar under `~/.cursor/da-sessions/` for cleaner later recall — prefer Agent if you expect to dig into points later.
- **Ask**: opposition still works; sidecar writes often fail.

## Exploring a point without breaking the debate

If DA raises something you want to investigate (code, evidence, “is that actually true?”), keep this chat in opposition mode. Open a **new** Ask chat and use `/fact-find` with a DA ref, e.g.:

```text
/fact-find DA response 2: <your question>
```

Fact-find stays neutral enquiry; it does not continue the devil’s-advocate stance. DA does **not** require fact-find — the link is optional when you want uninterrupted debate plus a side lab.

## What it is not

- Not a planner, coach, or “let’s redesign this together” mode
- Not for reaching mutual agreement
- Not org-required tooling (personal user pack)

**In one line:** you state a position; `/devils-advocate` tries to break it so you have to justify it properly — and you can fact-find raised questions in another chat without interrupting the fight.
