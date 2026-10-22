## Claude Code only

- **Sandbox escapes.** Leave the sandbox only after a command has failed with sandbox
  evidence.
  - Needs the escape: `op`, and writes to a repository's `.git/config` (`git init`,
    `git remote add`, `git config`).
  - Works sandboxed: `git add`, `git commit`, `git push`/`fetch` over SSH, `mise exec`,
    localhost TCP.
- **Excluded tools.** `docker`, `basecamp`, `herdr`, `xreview` and `review` are declared
  unsandboxed in `sandbox.excludedCommands`. Sandboxed, they return confident wrong
  answers: "unauthenticated", "no Codex pane", "daemon not running".
  - The declaration only applies when the tool is the first command of the Bash call, on
    its own. Do setup in a separate call, and never pipe or prefix these tools.
  - Never pass the escape flag for them.
- **Path-resolution guard.** Never chain commands after a leading `cd`: use absolute paths
  or `git -C`; a lone `cd` lasts only in the main session. Name directories, not a recursive
  `grep`/`rg` over `.`, which re-prompts in any tree that could hold a deny-glob match.
- **Plan workspaces.** Delete a finished `.superpowers/sdd/<plan>` workspace with
  `sdd-clean <workspace>`, never `rm -rf`.
- **Subagents.** Use the named types in `~/.claude/agents/`. Each pairs a model with an
  effort, which the Agent tool cannot set per call.

  | Type | Use for |
  |---|---|
  | `sp-mechanical` | tasks from a clear plan |
  | `sp-standard` | integration, debugging, scoped review |
  | `sp-reviewer` | cold diff review |
  | `sp-architect` | design, plan review, the final whole-branch review |

  Go up a tier when a task is harder than its label, and say which tier you used when it
  isn't obvious.
- **Parallel tasks.** A plan runs entirely in its own worktree; never create a worktree for
  one of its tasks. Plans give each task a `Depends on:` line. A batch is tasks with no
  pending dependency, disjoint files (neither one's tests load the other's), and no shared
  test resource such as a database, server or port. Dispatch a batch's implementers
  together in that worktree. They do not commit, and they run only their focused tests.
  The controller then commits each task on its own, one commit at a time. It reviews each
  task on exactly that commit, and runs the full suite once per batch.
- **Pushing.** Push in a Bash call of its own, as one plain command:
  `git push [options] <remote> <branch>` (for another repository, `git -C <path> push …`),
  optionally piped to `tail`/`head`. The push guard denies a push chained after a commit, a
  push with a comment, and a push inside a shell or substitution. It also runs gitleaks on
  the outgoing commits. A genuine false positive gets its fingerprint in `.gitleaksignore`,
  committed on the branch being pushed. While that file exists, push refs by name, never
  `--tags`/`--all`.
- **Cross-review** with Codex runs through the `cross-review` skill (`xreview`). It uses
  the repository's existing Codex pane; never open another. `xreview dispatch` needs
  `--checkpoint spec|plan|pre-merge`.
- **Guard bypasses** (`FORGE_GUARD=off`, `XREVIEW_GUARD=off`, `WT_GUARD=off`): use one only
  when Michael asks for it in this conversation, and say so in the MR.
