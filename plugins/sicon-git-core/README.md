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
- Remap line ranges from one commit to another for a single path (`Move-GitCoreLineRanges`)

It does not own Azure DevOps REST, pull-request create, destructive git, commit-message policy, or agent commands.

Add a function here only when it is a generic local git primitive any later workflow could need. Do not add a verb because one consuming pack needs it for its own register, policy, review, or forge semantics.

## Usage

Other Sicon workflows load this library. There is no `/git-core` command — do not run this plugin from chat.
