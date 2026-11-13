## Claude Code only

- **Sandbox escapes.** Leave the sandbox only after a command has failed with sandbox evidence.
  - Needs the escape: `op`, and git configuration writes in any repository: `init`,
    `clone`, `config`, `remote add`, `branch -u`, `submodule`, `worktree add`,
    `switch --track`, or a new branch started from a remote ref (`switch -c b origin/x`).
  - Works sandboxed: git `add`, `commit`, `push`/`fetch` over SSH, `mise exec`, local TCP.
- **Excluded tools.** `docker`, `basecamp`, `herdr`, `wt`, `xreview` and `review` are declared
  unsandboxed in `sandbox.excludedCommands`. Sandboxed, they fail partway or return confident
  wrong answers: "unauthenticated", "no Codex pane", "daemon not running".
  - The declaration only applies when the tool is the first command of the Bash call, on its own.
    Do setup in a separate call; never pipe or prefix these tools, or pass the escape flag for them.
- **Path-resolution guard.** Never chain commands after a leading `cd`: use absolute paths
  or `git -C`; a lone `cd` lasts only in the main session. Name directories, not a recursive
  `grep`/`rg` over `.`, which re-prompts in any tree that could hold a deny-glob match.
- **Cleanup never blocks a run.** Delete a finished `.superpowers/sdd/<plan>` workspace with
  `sdd-clean <workspace>`, never `rm -rf`. Other deletions and container removals wait until
  the run's work is done and go together, or into the final report as commands.
- **Subagents.** Use the named types in `~/.claude/agents/`; each pairs a model with an effort.

  | Type | Use for |
  |---|---|
  | `sp-mechanical` | tasks from a clear plan |
  | `sp-standard` | integration, debugging, scoped review, fix rounds, plan-run controllers, merges |
  | `sp-reviewer` | cold diff review, every per-task review and re-review |
  | `sp-architect` | design, plan review, the final whole-branch review; a fix only after an `sp-standard` attempt at it failed |
  | `web-researcher` | all web research, a skill's researchers included: it holds only WebFetch and WebSearch, so the dispatcher passes it any reference text and saves its notes |

  Go up a tier when a task is harder than its label; say which tier you used if not obvious.
  Reviews never run as forks: a fork inherits the whole conversation, your reasoning included.
- **Plan runs.** Plans give each task a `Depends on:` line and run in the line's checkout, never in
  a worktree per task. To run one, first load the `plan-run` skill: it overrides superpowers.
- **Claude review findings.** For `sp-reviewer` and `sp-architect`, Fix now narrows: a finding gets
  code only when it names an Engineering judgement cost or a real caller reaching its failure (a
  code path, an input the system accepts, an attacker its threat model names; unsure counts as
  real). Any other finding gets one line under Rulings. Codex findings: the `cross-review` skill.
- **Dispatching a `wt` line.** In the turn that ran `wt`, find the checkout's session in
  `ListAgents` (named after it) and `SendMessage` it the brief: goal, sources, constraints, branch,
  what to report back. That session runs the line itself, spec included, with its own subagents and
  `xreview`. If `ListAgents` does not list it, tell Michael; never run the line in the main session.
- **Pushing.** Push in its own Bash call as one plain command: `git push [options] <remote>
  <branch>` (other repo: `git -C <path> push …`), optionally piped to `tail`/`head`. The push
  guard denies a push chained after a commit, with a comment, or in a shell or substitution, and
  runs gitleaks on the push. A genuine false positive's fingerprint goes in `.gitleaksignore`,
  committed on the pushed branch. While that file exists, push refs by name, never `--tags`/`--all`.
- **Cross-review** with Codex runs through the `cross-review` skill (`xreview`). It uses an
  existing Codex pane; never open another. If the driver itself reviews a `wt` line, its `xreview`
  calls pass `-C <checkout>`. `xreview dispatch` needs `--checkpoint spec|plan|pre-merge`.
- **Guard bypasses** (`FORGE_GUARD=off`, `XREVIEW_GUARD=off`, `WT_GUARD=off`): use one only
  when Michael asks for it in this conversation, and say so in the MR.
