## Claude Code only

- **Sandbox escapes.** Leave the sandbox only after a command has failed with sandbox
  evidence.
  - Needs the escape: `op`, and writes to a repository's `.git/config` (`git init`,
    `git remote add`, `git config`).
  - Works sandboxed: `git add`, `git commit`, `git push`/`fetch` over SSH, `mise exec`,
    localhost TCP.
- **Excluded tools.** `docker`, `basecamp`, `herdr` and `xreview` are declared unsandboxed
  in `sandbox.excludedCommands`. Sandboxed, they return confident wrong answers:
  "unauthenticated", "no Codex pane", "daemon not running".
  - The declaration only applies when the tool is the first command of the Bash call, on
    its own. Do setup in a separate call, and never pipe or prefix these tools.
  - Never pass the escape flag for them.
- **Recursive search.** A recursive `grep`/`rg` over `.` in a tree that could hold a
  deny-glob match (such as `**/secrets.*.yml`) re-prompts every time. Name the directories
  instead.
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
