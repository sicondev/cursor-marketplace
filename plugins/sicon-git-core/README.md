# Sicon Git Core

Shared local git library for other Sicon plugins. There is no slash command.

Install from the Sicon Team Marketplace, then enable the plugin.

## Scope

Git Core owns generic local operations:

- Run git with an argument list without throwing on a non-zero exit
- Read the current HEAD commit SHA
- Stage and commit specific file paths with a caller-supplied message
- Push the current branch, or a named remote and branch
- Parse unified-diff hunks (`git diff -U0`) into HEAD path and line ranges

It does not own Azure DevOps REST, pull-request create, destructive git, commit-message policy, or agent commands.

## Usage

Other Sicon workflows load this library. There is no `/git-core` command — do not run this plugin from chat.
