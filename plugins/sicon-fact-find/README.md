# Sicon Fact Find

Neutral, read-only exploratory enquiry via /fact-find, with an optional topic and optional Devil's Advocate references

Install from the Sicon Team Marketplace, then use `/fact-find` in chat.

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

The supported usage contract is the `/fact-find` slash command with either no arguments or an optional topic. Ask-mode enforcement, neutrality, response depth, and optional DA-reference resolution remain agent-dependent.
