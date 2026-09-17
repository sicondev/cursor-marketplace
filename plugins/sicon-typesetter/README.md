# Typesetter

Prep dirty files against each repository's own format and lint tooling before hard gates are on.

Install from the **Sicon Team Marketplace**, then use the slash commands when you want an optional readiness pass on what you already changed.

## What it does

- Finds **dirty** files in the current git repo
- Runs the repo's format or lint tools on those paths only
- Shows drift or issues, then lets you leave them or fix

This is a bridge workflow. Once format and lint are enforced in CI or the build, you will need it less.

## Requirements

The product repo must already define tooling (for example EditorConfig + `dotnet format`, Prettier, or ESLint). Typesetter does not ship house style.
