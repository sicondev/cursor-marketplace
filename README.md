# Sicon Cursor Team Marketplace

This repo is the **Sicon Team Marketplace mirror** for Cursor plugins: `plugins/` plus `.cursor-plugin/marketplace.json`. Upload or sync this tree, then import/refresh in Cursor Dashboard → Plugins. CI marketplace publish is deferred.

This checkout is **multi-plugin** (several plugins in one repo). That is the supported layout.

## Consumers

In Cursor, install and enable plugins from the Sicon Team Marketplace (for example `sicon-fact-find`, `sicon-coding-standards`, `sicon-devils-advocate`). Use each plugin’s slash commands or skills after enable.

## Producers — start in ai-devtools

If you opened this repo to **change a tool**, author it in **ai-devtools** `contrib/<id>` (or the matching org pack). Do not invent a parallel copy only in this marketplace tree.

### Why

- **Dogfood and hygiene** — ship what you actually use from the contrib lane.
- **One source of truth** — avoid duplicating the same command/skill in two places that drift.
- **Gate before catalog** — `pinch plugin publish` runs iterate checks, version confirm, export, and validate before the catalog entry lands.

### Publish a contrib pack as a plugin

From an **ai-devtools** checkout, per tool:

```text
pinch plugin publish <pack-id>
```

That lane loads the plugin pincher doc, runs the iterate gate, confirms the next semver, then writes via `Export-ContribCursorPlugin.ps1` into `plugins/sicon-<id>/` here (security scan + `node scripts/validate-template.mjs`). Commit/push this marketplace repo and refresh the Team Marketplace in the Dashboard.

## Template leftovers

`plugins/starter-simple` and `plugins/starter-advanced` are Cursor template samples, not Sicon product plugins.
