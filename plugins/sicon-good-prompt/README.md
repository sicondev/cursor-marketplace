# Sicon Good Prompt

Coach implementation briefs via /good-prompt — gap-fill until handoff to Plan

Install from the Sicon Team Marketplace, then use `/good-prompt` in chat.

## Usage

Use a new chat in Ask mode when possible:

```text
/good-prompt
/good-prompt add validation to the invoice approval submit path
```

Bare `/good-prompt` acknowledges the coaching mode and asks for the draft task. Text following the command is treated as the draft task immediately.

Good-prompt coaches gap-fill until you have a paste-ready implementation brief for Plan (default) or Ask/Agent when that fits. It asks one gap per turn, tracks confirmed fields, and emits a brief on handoff — it does not plan or implement in-thread.

## Reliability

The supported usage contract is the `/good-prompt` slash command with either no arguments or an optional draft task. Multi-turn coaching shape, Ask-mode enforcement, medium gate, handoff brief format, targeted repo reads, and PR evidence pack depth remain agent-dependent.
