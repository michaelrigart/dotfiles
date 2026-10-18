# Sandbox Write Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nothing a sandboxed Bash command writes can later run outside the sandbox without review.

**Architecture:** Three layers. (1) The sandbox write set drops `~/.config` and `~/.local/bin`, and denies git hooks/config files and the vault's `.obsidian` everywhere. (2) Everything of ours that runs unsandboxed — hooks, the statusline, `xreview` and its helpers — pins its `PATH` (overridable only through `PINNED_PATH` for tests), and the push guard's git calls run with lazy fetch off. (3) A zsh wrapper makes `chezmoi apply`/`update` deploy a fresh clone of origin's `main` after checking the checkout is a clean `main` equal to it.

**Tech Stack:** bash (Homebrew bash 5 for hooks), zsh (the wrapper), Python 3 (`/usr/bin/python3`), git, jq, the chezmoi `modify_` settings script.

**Status:** Implemented on `feat/sandbox-write-boundary`. Do not run it again; the spec records what changed after this plan was approved.

**Spec:** `docs/superpowers/specs/2026-10-16-sandbox-write-boundary-design.md` (Approved; §2 corrected in 1721ab7 to cover `xreview`).

## Global Constraints

- No change adds a permission prompt or a sandbox escape.
- The pinned hook `PATH` is exactly `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin`. For `xreview`, `xreview-rpc` and `codex-daemon` it is exactly `$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin`.
- Every pinned script reads `PATH` as `${PINNED_PATH:-<its default>}`, before running any other command. `PINNED_PATH` exists for the suites only.
- Hook and statusline commands in the settings run `/opt/homebrew/bin/bash` by absolute path.
- Suites are `tests/<subject>.test.sh`, mode 755, executed directly (never through an interpreter); results as passed/total. A suite that measures the live sandbox carries `# test-requires: sandboxed, fresh-session`.
- This repo is public: nothing private in any file.
- Implementers do not commit; the controller commits each task. Never start a Bash call with `cd`.

## Review Focus

1. A stub on the suite's `PATH` must still reach the script under test through `PINNED_PATH`, or existing suites silently test the real tools: every migrated suite must keep its exact pass count (Tasks 2-5, "unchanged totals" steps).
2. A hook run with a hostile `PATH` and no `PINNED_PATH` must run none of the hostile tools, the shell itself included (Task 4's `hook-path` suite, which executes the settings' own command strings).
3. `chezmoi apply --dry-run --verbose`, the preview AGENTS.md documents, must take the wrapper's path and preview the fresh clone (Task 6, "dry-run" case).
4. A git branch named `config` or `hooks` must stay creatable sandboxed, and `git init` in `$TMPDIR` must keep working: the deny globs name `.git/hooks`, `.git/config` and `.git/modules/**` inside the work roots only (Task 1, scope assertion; Task 7 live cases).
5. The wrapper must not leave its temporary clone behind on any outcome (Task 6, "temporary directory removed" assertion on a refusal after the clone and on success).

## Execution

Batch 1: Tasks 1, 2, 3, 5, 6, 7 (no dependencies, disjoint files). Batch 2: Task 4 (depends on 1, 2, 3). Dispatch each batch's implementers together; the controller commits and reviews each task on its own commit, and runs `./tests/run.sh` once per batch.

Controller steps outside the tasks: set the spec's status to `In progress` before batch 1; after batch 2, the whole-branch review; then the final commit (spec `Implemented`, this plan `**Status:** Implemented`), then the Codex pre-merge review, then push. Michael runs `chezmoi apply` and, in a fresh session, `./tests/run.sh live-write-boundary`. This session cannot probe how the sandbox enforces a `denyWrite` glob, because the settings deploy only on apply. If the live suite reports a git-file or `.obsidian` case as `WRITABLE`, that form is not enforced. The follow-up then adds the same paths as `Edit(...)` deny rules, which Claude Code merges into the sandbox's write denials, and re-runs the suite.

---

### Task 1: The settings — write set, deny rules, absolute interpreters

**Depends on:** none

**Files:**
- Modify: `dot_claude/modify_private_settings.json` (the `--arg sl` and `--arg herdr_hook` lines; the hook `command` strings; `sandbox.filesystem.allowWrite`; a new `sandbox.filesystem.denyWrite`)
- Test: `tests/claude-settings.test.sh`

**Interfaces:**
- Produces: hook and statusline commands of the form `/opt/homebrew/bin/bash $HOME/.claude/<script>` (Task 4's `hook-path` suite executes them).

- [ ] **Step 1: Write the failing tests.** In `tests/claude-settings.test.sh`:
  - `EXP_DENY` stays as it is: the denials go in `sandbox.filesystem.denyWrite` (below), the
    key that names sandbox writes directly. The git-file denials are scoped to the four work
    roots. A bare `**/.git/config` would also deny every sandboxed `git init`, `git clone` and
    `git config` in `$TMPDIR`, which the suites and agents rely on.
  - Replace the allowWrite block (the comment starting `# allowWrite exists so ordinary work` through the `allowWrite is scoped` assertion) with:
    ```bash
    # allowWrite keeps ordinary work sandboxed: source trees, the chezmoi source, documents and
    # the vault. ~/.config and ~/.local/bin are out (spec 2026-10-16, sandbox write boundary):
    # what is written there runs later outside the sandbox — shells, git, mise, herdr, the
    # hooks, the excluded commands. Credential denials still outrank allowWrite.
    EXP_ALLOW_WRITE='["~/Code","~/.local/share/chezmoi","~/Documents","~/Library/Mobile Documents/iCloud~md~obsidian"]'
    jq_is ".sandbox.filesystem.allowWrite == $EXP_ALLOW_WRITE" true \
          "allowWrite is exactly the four work roots"
    # denyWrite: in each work root, at any depth, git hooks and the git files that name
    # commands; the chezmoi checkout's own top-level .git; the vault's .obsidian. Objects, refs
    # and the index stay writable, a branch named config or hooks still is, and $TMPDIR is
    # untouched (suites and agents git init there).
    GITFILES='[".git/hooks",".git/hooks/**",".git/config",".git/config.worktree",
     ".git/modules/**/hooks",".git/modules/**/hooks/**",".git/modules/**/config",
     ".git/modules/**/config.worktree",".git/worktrees/*/config.worktree"]'
    ROOTS='["~/Code","~/.local/share/chezmoi","~/Documents","~/Library/Mobile Documents/iCloud~md~obsidian"]'
    EXP_DENY_WRITE=$(jq -cn --argjson g "$GITFILES" --argjson r "$ROOTS" '
      [$r[] as $root | $g[] | "\($root)/**/\(.)"]
      + [$g[] | "~/.local/share/chezmoi/\(.)"]
      + ["~/Library/Mobile Documents/iCloud~md~obsidian/Documents/*/.obsidian",
         "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/*/.obsidian/**"]')
    jq_is ".sandbox.filesystem.denyWrite == $EXP_DENY_WRITE" true \
          "denyWrite is exactly the executing git files in each work root, and .obsidian"
    jq_is '[.sandbox.filesystem.denyWrite[] | select(startswith("**") or startswith("/tmp") or startswith("/private"))] | length' 0 \
          "no deny glob reaches outside the work roots, so git init in TMPDIR still works"
    jq_is '[.sandbox.filesystem.denyWrite[] | select(test("/refs|/objects|/index$"))] | length' 0 \
          "no deny glob reaches refs, objects or the index"
    jq_is '[.sandbox.filesystem.denyWrite[] | select((test("/\\.git/") or test("/\\.obsidian(/|$)")) | not)] | length' 0 \
          "every deny glob names a git file or .obsidian, never a bare config or hooks name"
    jq_is '[.sandbox.filesystem.allowWrite[] | select(test("(^|/)\\.ssh(/|$)") or test("(^|/)\\.aws(/|$)") or test("/op(/|$)"))] | length' 0 \
          "no credential path is writable through allowWrite"
    ```
  - Add, after section A's other checks:
    ```bash
    # Hooks and the statusline run outside the sandbox: their interpreter is named by absolute
    # path, so nothing on PATH can stand in for it (spec 2026-10-16, section 2).
    jq_is '[.hooks[][]?.hooks[]?.command, .statusLine.command
            | select(test("^(bash|sh|zsh|python3?) "))] | length' 0 \
          "no hook or statusline command starts with a bare interpreter"
    jq_is '[.hooks[][]?.hooks[]?.command, .statusLine.command
            | select(test("\\.(sh|py)\\b")) | select(startswith("/opt/homebrew/bin/bash ") | not)] | length' 0 \
          "every hook and statusline script runs under /opt/homebrew/bin/bash"
    ```
- [ ] **Step 2: Run** `./tests/claude-settings.test.sh` — the new cases FAIL, the rest PASS.
- [ ] **Step 3: Implement** in `dot_claude/modify_private_settings.json`:
  - `--arg sl "/opt/homebrew/bin/bash $HOME/.claude/statusline.sh"` and `--arg herdr_hook "/opt/homebrew/bin/bash '$HOME/.claude/hooks/herdr-agent-state.sh' session"`.
  - Every `"command": "bash $HOME/.claude/…"` becomes `"command": "/opt/homebrew/bin/bash $HOME/.claude/…"` (memory-health, the five PreToolUse guards, prompt-audit). The SessionStart `echo` command stays.
  - `sandbox.filesystem.allowWrite`: `["~/Code", "~/.local/share/chezmoi", "~/Documents", "~/Library/Mobile Documents/iCloud~md~obsidian"]`, and update its comment to say why `~/.config` and `~/.local/bin` are out (no apostrophes: the jq program is single-quoted).
  - `sandbox.filesystem.denyWrite`: built inside the jq program from the same two lists, so it equals `EXP_DENY_WRITE` element for element and in order:
    ```
    "denyWrite": (
      ["~/Code", "~/.local/share/chezmoi", "~/Documents", "~/Library/Mobile Documents/iCloud~md~obsidian"] as $roots
      | [".git/hooks", ".git/hooks/**", ".git/config", ".git/config.worktree",
         ".git/modules/**/hooks", ".git/modules/**/hooks/**", ".git/modules/**/config",
         ".git/modules/**/config.worktree", ".git/worktrees/*/config.worktree"] as $git
      | [$roots[] as $root | $git[] | "\($root)/**/\(.)"]
        + [$git[] | "~/.local/share/chezmoi/\(.)"]
        + ["~/Library/Mobile Documents/iCloud~md~obsidian/Documents/*/.obsidian",
           "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/*/.obsidian/**"])
    ```
    with a comment above it: what is written there runs outside the sandbox later; scoped to the work roots so `git init` in `$TMPDIR` keeps working (no apostrophes).
- [ ] **Step 4: Run** `./tests/claude-settings.test.sh` — every case PASSes.
- [ ] **Step 5: Report back.** The controller commits both files as "Close the sandbox write set to what runs nothing later".

---

### Task 2: The push guard — pinned PATH, lazy fetch off

**Depends on:** none

**Files:**
- Modify: `dot_claude/executable_git-forge-guard.sh`, `dot_claude/git-push-guard.py`
- Test: `tests/git-forge-guard.test.sh`

- [ ] **Step 1: Migrate the suite to `PINNED_PATH`.** Every place the suite runs the guard, the guard must see the suite's current `PATH`. In `run()` change `| bash "$GUARD"` to `| PINNED_PATH="$PATH" bash "$GUARD"`, and do the same for any other direct `bash "$GUARD"` invocation in the file (search for `$GUARD"`). Run `./tests/git-forge-guard.test.sh` and record the total: it must be unchanged by this step alone (the guard ignores `PINNED_PATH` until Step 4).
- [ ] **Step 2: Write the failing tests.** Add, at the end of the rule-4 section that uses `$DEL` (before the "moves the remote" cases), a case with its own fixture:
  ```bash
  # A remote-tracking ref pointing at a missing object, plus a promisor remote whose
  # uploadpack writes a marker: the guard's own git calls must never lazy-fetch (spec
  # 2026-10-16, sandbox write boundary, section 2). The verdict is the usual one for a
  # dangling ref (the outgoing commits cannot be listed: deny), and no marker appears.
  LAZY=$(cp -R "$DEL" "$TMP/dellazy" && printf '%s' "$TMP/dellazy")
  git -C "$LAZY" switch -q work
  git -C "$LAZY" commit -q --allow-empty -m "lazy work"
  printf '%s\n' 1111111111111111111111111111111111111111 > "$LAZY/.git/refs/remotes/origin/ghost"
  git -C "$LAZY" config remote.origin.promisor true
  git -C "$LAZY" config remote.origin.partialclonefilter blob:none
  git -C "$LAZY" config remote.origin.uploadpack "touch $TMP/lazy-marker; git-upload-pack"
  expect deny "a dangling remote ref with a promisor remote" "$LAZY" 'git push origin work'
  if [ -e "$TMP/lazy-marker" ]; then
    fail=$((fail + 1)); printf '  FAIL %s\n' "the guard lazy-fetched through the promisor remote"
  else
    pass=$((pass + 1)); printf '  ok   %s\n' "the guard never lazy-fetches"
  fi
  ```
  Also add a case proving the pin: a stub `git` that writes a marker, first on the suite's `PATH` but NOT in `PINNED_PATH`:
  ```bash
  EVIL="$TMP/evilbin"; mkdir -p "$EVIL"
  printf '#!/bin/sh\ntouch "%s/evil-marker"\nexec /usr/bin/git "$@"\n' "$TMP" > "$EVIL/git"; chmod 755 "$EVIL/git"
  ( PATH="$EVIL:$PATH"; unset PINNED_PATH
    jq -n --arg c 'git push origin work' --arg d "$DEL" \
      '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
      | bash "$GUARD" >/dev/null )
  if [ -e "$TMP/evil-marker" ]; then
    fail=$((fail + 1)); printf '  FAIL %s\n' "the guard ran a git from the caller's PATH"
  else
    pass=$((pass + 1)); printf '  ok   %s\n' "the guard's PATH is pinned"
  fi
  ```
- [ ] **Step 3: Run** the suite — both new cases FAIL (the marker files appear).
- [ ] **Step 4: Implement.**
  - `dot_claude/executable_git-forge-guard.sh`: as the first command after the comment header (before `payload=$(cat)` or anything else that runs a program), add:
    ```bash
    # Runs outside the sandbox, so it resolves nothing a sandboxed command can write: no
    # ~/.local/bin, no mise shim (spec 2026-10-16, sandbox write boundary). PINNED_PATH is
    # for the suites only.
    PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH
    ```
  - `dot_claude/git-push-guard.py`:
    - In `Repo.run`, when `env is None`, use `dict(os.environ, GIT_NO_LAZY_FETCH="1")`; when an env is passed, add `GIT_NO_LAZY_FETCH="1"` to a copy of it unless the caller is the patch listing (see next bullet). Simplest form: give `run` a keyword `lazy=False`; build `env = dict(env if env is not None else os.environ)`, then `if not lazy: env["GIT_NO_LAZY_FETCH"] = "1"`.
    - `expected_commits` passes `lazy=True` (it reads the same patches gitleaks reads, which may need blobs in a genuine partial clone); `run_gitleaks` is not a `Repo.run` call and keeps its env unchanged. Every other `repo.run` call, the scan's `rev-list`, `log --no-walk`, `ls-tree`, `hash-object` and `rev-parse` included, gets lazy fetch off by default.
    - Update the `scan` docstring's sentence about environment to say: every git call runs with lazy fetch off except the patch listing and gitleaks, which may need blobs in a genuine partial clone; a sandboxed command can no longer configure a promisor remote.
- [ ] **Step 5: Run** `./tests/git-forge-guard.test.sh` — every case PASSes, and the total is Step 1's plus 2.
- [ ] **Step 6: Report back.** The controller commits the three files as "Pin the push guard's PATH and keep its git calls from lazy-fetching".

---

### Task 3: The statusline — pinned PATH

**Depends on:** none

**Files:**
- Modify: `dot_claude/executable_statusline.sh`
- Test: `tests/statusline.test.sh`

- [ ] **Step 1: Migrate the suite.** In `run()`, add `PINNED_PATH="$T/$1:/usr/bin:/bin"` to the `env -i …` list (beside `PATH=`). Run `./tests/statusline.test.sh`; the total is unchanged.
- [ ] **Step 2: Write the failing test.** Before the final summary:
  ```bash
  # The statusline runs outside the sandbox: a tool on the caller's PATH must not reach it.
  mkdir -p "$T/evil"
  for t in git jq tagteam; do
    printf '#!/bin/sh\ntouch "%s/evil-%s"\n' "$T" "$t" > "$T/evil/$t"; chmod 755 "$T/evil/$t"
  done
  in_dir repo-main
  printf '%s' "$INPUT" | env -i HOME="$T" PATH="$T/evil:/usr/bin:/bin" COLUMNS=120 bash "$SL" >/dev/null 2>&1
  if ls "$T"/evil-* >/dev/null 2>&1; then _fail "the statusline's PATH is pinned" "$(ls "$T"/evil-*)"
  else _pass "the statusline's PATH is pinned"; fi
  INPUT=$INPUT_PLAIN
  ```
- [ ] **Step 3: Run** — the new case FAILs.
- [ ] **Step 4: Implement.** After `export LC_ALL=…` (line 5), add:
  ```bash
  # Runs outside the sandbox, so it resolves nothing a sandboxed command can write (spec
  # 2026-10-16, sandbox write boundary). PINNED_PATH is for the suite only.
  PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH
  ```
- [ ] **Step 5: Run** — every case PASSes; total is Step 1's plus 1. Check added lines are ASCII: `git diff -U0 -- dot_claude/executable_statusline.sh | rg '^\+' | LC_ALL=C rg -c '[^\t -~]'` prints nothing.
- [ ] **Step 6: Report back.** The controller commits both files as "Pin the statusline's PATH".

---

### Task 4: The other hooks — pinned PATH, and the hostile-PATH suite

**Depends on:** Task 1 (absolute interpreters in the settings), Task 2, Task 3 (their pins)

**Files:**
- Modify: `dot_claude/executable_path-resolution-guard.sh`, `dot_claude/executable_worktree-guard.sh`, `dot_claude/executable_xreview-guard.sh`, `dot_claude/executable_xreview-apply-guard.sh`, `dot_claude/hooks/executable_herdr-agent-state.sh`, `dot_claude/hooks/executable_memory-health.sh`, `dot_claude/hooks/executable_prompt-audit.sh`
- Modify (migration only): `tests/path-resolution-guard.test.sh`, `tests/worktree-guard.test.sh`, `tests/xreview-guard.test.sh`, `tests/xreview-apply-guard.test.sh`, `tests/memory-health.test.sh`, `tests/prompt-audit.test.sh`, and whichever suite runs `herdr-agent-state.sh` (find it with `rg -l 'herdr-agent-state' tests`)
- Create: `tests/hook-path.test.sh` (mode 755)

**Interfaces:**
- Consumes: Task 1's command strings (`/opt/homebrew/bin/bash $HOME/.claude/<script>`), Tasks 2-3's pins.

- [ ] **Step 1: Migrate each hook suite to `PINNED_PATH`.** For each suite listed, every invocation of the hook under test gets `PINNED_PATH="$PATH"` (or the explicit `PATH` value the line sets, e.g. `env PATH=/bin /bin/bash "$GUARD"` becomes `env PATH=/bin PINNED_PATH=/bin /bin/bash "$GUARD"`). Record each suite's total before and after: unchanged.
- [ ] **Step 2: Write the hostile-PATH suite.** Create `tests/hook-path.test.sh`:
  ```bash
  #!/usr/bin/env bash
  # Every hook and statusline command the settings configure runs outside the sandbox. Each is
  # executed here exactly as configured, with a hostile directory first on PATH holding stubs
  # for the shells and every tool the hooks use; each stub writes a marker. No marker may
  # appear (spec 2026-10-16, sandbox write boundary, section 2). The command list comes from
  # the settings, so a hook added later without the pin fails here.
  #
  #   ./tests/hook-path.test.sh   (sandboxed is fine)
  set -uo pipefail
  SRC="$(cd "$(dirname "$0")/.." && pwd)"
  MOD="$SRC/dot_claude/modify_private_settings.json"
  [ -f "$MOD" ] || { echo "missing script under test: $MOD" >&2; exit 2; }
  [ -x /opt/homebrew/bin/bash ] || { echo "no /opt/homebrew/bin/bash" >&2; exit 2; }
  pass=0; fail=0
  _pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
  _fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
  T="$(mktemp -d "${TMPDIR:-/tmp}/hook-path.XXXXXX")"; trap 'rm -rf "$T"' EXIT

  # A mirror of ~/.claude built from the source, at $T/.claude: HOME=$T makes the commands'
  # $HOME/.claude/<script> resolve to it.
  mkdir -p "$T/.claude/hooks"
  for f in "$SRC"/dot_claude/executable_*.sh "$SRC"/dot_claude/*.py; do
    b=$(basename "$f"); cp "$f" "$T/.claude/${b#executable_}"
  done
  for f in "$SRC"/dot_claude/hooks/executable_*.sh; do
    b=$(basename "$f"); cp "$f" "$T/.claude/hooks/${b#executable_}"
  done

  HOSTILE="$T/hostile"; mkdir -p "$HOSTILE"
  for t in bash sh zsh jq git python3 python cat sed awk grep rg fd tr head tail wc cut sort \
           date stat mktemp env herdr tagteam glab gh gitleaks; do
    printf '#!/bin/sh\necho "%s" >> "%s/marker"\nexit 0\n' "$t" "$T" > "$HOSTILE/$t"
    chmod 755 "$HOSTILE/$t"
  done

  # A real repository for the payloads, and an empty state home.
  git init -q "$T/repo" && git -C "$T/repo" commit -q --allow-empty -m init
  PAYLOAD=$(jq -cn --arg d "$T/repo" '{hook_event_name:"PreToolUse",tool_name:"Bash",
    session_id:"hook-path",cwd:$d,tool_input:{command:"git push origin main"},
    transcript_path:"/nonexistent"}')
  STATUS=$(jq -cn --arg d "$T/repo" '{model:{display_name:"Opus"},workspace:{current_dir:$d}}')

  SETTINGS=$(printf '{}' | HOME="$T" /bin/bash "$MOD") || { echo "settings did not render" >&2; exit 2; }
  n=0
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    case $cmd in echo\ *) continue ;; esac          # the SessionStart env export runs no script
    n=$((n + 1)); rm -f "$T/marker"
    input=$PAYLOAD; case $cmd in *statusline*) input=$STATUS ;; esac
    printf '%s' "$input" | env -i HOME="$T" XDG_STATE_HOME="$T/state" TMPDIR="$T" \
      PATH="$HOSTILE:/usr/bin:/bin:/opt/homebrew/bin" /bin/sh -c "$cmd" >/dev/null 2>&1
    if [ -e "$T/marker" ]; then _fail "no hostile tool runs: $cmd" "$(tr '\n' ' ' < "$T/marker")"
    else _pass "no hostile tool runs: ${cmd#/opt/homebrew/bin/bash }"; fi
  done < <(printf '%s' "$SETTINGS" | jq -r '.hooks[][]?.hooks[]?.command, .statusLine.command')
  [ "$n" -ge 9 ] && _pass "all $n configured hook and statusline commands were exercised" \
    || _fail "all configured commands were exercised" "only $n"

  printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  ```
  `chmod 755 tests/hook-path.test.sh`. The `env -i` keeps every `HERDR_*` variable out, so `herdr-agent-state.sh` takes its no-pane early exit and contacts no live herdr.
- [ ] **Step 3: Run** `./tests/hook-path.test.sh` — the seven hooks not yet pinned FAIL; the forge guard, the statusline and the memory-health command line may pass or fail depending on what they call first.
- [ ] **Step 4: Implement.** In each of the seven scripts, as the first command after the comment header, before anything that runs a program:
  ```bash
  # Runs outside the sandbox, so it resolves nothing a sandboxed command can write (spec
  # 2026-10-16, sandbox write boundary). PINNED_PATH is for the suites only.
  PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH
  ```
  If a hook calls a tool from `~/.local/bin`, call it as `"$HOME/.local/bin/<tool>"`.
- [ ] **Step 5: Run** `./tests/hook-path.test.sh` (every case PASSes) and each migrated suite (totals unchanged).
- [ ] **Step 6: Report back.** The controller commits the hooks, the migrated suites and `tests/hook-path.test.sh` as "Pin every hook's PATH, and prove it against a hostile one", after checking `tests/hook-path.test.sh` is mode 100755.

---

### Task 5: `xreview`, `xreview-rpc`, `codex-daemon` — pinned PATH

**Depends on:** none

**Files:**
- Modify: `dot_local/bin/executable_xreview`, `dot_local/bin/executable_xreview-rpc`, `dot_local/bin/executable_codex-daemon`
- Test: `tests/xreview.test.sh`, `tests/xreview-rpc.test.sh`

- [ ] **Step 1: Migrate the suites.** In `tests/xreview.test.sh`, right after `export PATH="$STUB:$PATH"` (line ~268) add `export PINNED_PATH="$PATH"`; at the `PATH="$STUB2:$PATH" bash "$XREVIEW" round` line add `PINNED_PATH="$STUB2:$PATH"`; search for any other `PATH=` assignment that runs `$XREVIEW` and mirror it. Do the same in `tests/xreview-rpc.test.sh` for its invocations of the script under test. Totals unchanged.
- [ ] **Step 2: Write the failing tests.** In `tests/xreview.test.sh`, before the summary:
  ```bash
  # P1-P2: xreview runs outside the sandbox, so a jq or git reached through a mise shim (whose
  # repository mise.toml an agent can edit) or anything else on the caller's PATH must not run.
  HOSTILE="$ROOT/hostile"; mkdir -p "$HOSTILE" "$ROOT/hosthome"
  for t in jq git herdr python3; do
    printf '#!/bin/sh\necho %s >> "%s/hostile-marker"\nexit 0\n' "$t" "$ROOT" > "$HOSTILE/$t"; chmod 755 "$HOSTILE/$t"
  done
  # bash itself is on the hostile list, and xreview runs as an executable, the way the Bash
  # tool runs an excluded command: its shebang must not resolve bash through PATH.
  printf '#!/bin/sh\necho bash >> "%s/hostile-marker"\nexit 0\n' "$ROOT" > "$HOSTILE/bash"; chmod 755 "$HOSTILE/bash"
  cp "$XREVIEW" "$ROOT/xreview-exec"; chmod 755 "$ROOT/xreview-exec"
  out="$( (unset PINNED_PATH; HOME="$ROOT/hosthome" PATH="$HOSTILE:$PATH" "$ROOT/xreview-exec" round) 2>&1)"
  is "P1 xreview round runs with a hostile PATH (bash included) and no PINNED_PATH" "$( [ -e "$ROOT/hostile-marker" ] && cat "$ROOT/hostile-marker" | tr '\n' ' ' || echo clean)" clean
  is "P2 and still answers" "$(printf '%s' "$out" | grep -c '^[0-9]')" 1
  ```
  In `tests/xreview-rpc.test.sh`, add the analogous case for one `xreview-rpc` subcommand that needs no daemon (pick one the suite already exercises against its stubs), asserting the hostile marker is absent.
- [ ] **Step 3: Run** both suites — the new cases FAIL.
- [ ] **Step 4: Implement.**
  - `executable_xreview` line 1: `#!/usr/bin/env bash` becomes `#!/opt/homebrew/bin/bash`, so the Bash tool's direct run of the excluded command never resolves `bash` through `PATH` (a mise shim would load a repository's `mise.toml` before the pin below runs). `executable_codex-daemon` (`#!/bin/sh`) and `executable_xreview-rpc` (`#!/usr/bin/python3`) already name absolute interpreters.
  - `executable_xreview`, right after `set -euo pipefail` (line 19):
    ```bash
    # Runs outside the sandbox (an excluded command), so it resolves no mise shim, which would
    # load a repository's mise.toml (spec 2026-10-16, sandbox write boundary). ~/.local/bin
    # stays first for the codex launcher; the sandbox cannot write it. PINNED_PATH is for the
    # suites only.
    PATH=${PINNED_PATH:-$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH
    ```
  - `executable_codex-daemon`, right after `set -eu`: the same line, with the same comment adapted ("called by xreview and by Michael").
  - `executable_xreview-rpc`, right after the imports:
    ```python
    # Runs outside the sandbox (called by xreview), so it resolves no mise shim (spec
    # 2026-10-16, sandbox write boundary). PINNED_PATH is for the suites only.
    os.environ["PATH"] = os.environ.get("PINNED_PATH") or (
        os.path.expanduser("~/.local/bin") + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
    ```
    (add `import os` if it is not imported).
- [ ] **Step 5: Run** both suites — every case PASSes; totals are Step 1's plus the new cases.
- [ ] **Step 6: Report back.** The controller commits the five files as "Pin xreview's PATH and its helpers'".

---

### Task 6: The `chezmoi` wrapper

**Depends on:** none

**Files:**
- Modify: `dot_config/zsh/functions` (append the wrapper at the end)
- Create: `tests/chezmoi-wrapper.test.sh` (mode 755, `#!/usr/bin/env zsh`)

**Interfaces:**
- Produces: the zsh function `chezmoi`, which wraps `command chezmoi`.

- [ ] **Step 1: Write the failing suite.** Create `tests/chezmoi-wrapper.test.sh`:
  ```zsh
  #!/usr/bin/env zsh
  # Tests the chezmoi wrapper in dot_config/zsh/functions (spec 2026-10-16, sandbox write
  # boundary, section 3): apply and update deploy a fresh clone of origin's main, only from a
  # clean main checkout equal to it; --dirty-ok applies the working tree. chezmoi is a stub
  # that records its arguments and what its --source holds; git is real, origin is a local bare
  # repository.
  #
  #   ./tests/chezmoi-wrapper.test.sh   (sandboxed is fine)
  emulate -L zsh
  setopt no_unset pipe_fail
  SRC=${0:A:h:h}
  FUNCS=$SRC/dot_config/zsh/functions
  [[ -f $FUNCS ]] || { print -u2 "missing file under test: $FUNCS"; exit 2 }
  integer pass=0 fail=0
  _pass() { print "  PASS: $1"; (( pass++ )) }
  _fail() { print "  FAIL: $1\n    | got: $2"; (( fail++ )) }
  T=$(mktemp -d "${TMPDIR:-/tmp}/chezmoi-wrapper.XXXXXX")
  trap 'rm -rf "$T"' EXIT
  export GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1 TMPDIR=$T/tmp XDG_CACHE_HOME=$T/cache
  mkdir -p $T/tmp $T/bin $T/cache
  print -r -- $'[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main' > $GIT_CONFIG_GLOBAL

  # The stub: `chezmoi source-path` prints the checkout; anything else logs its arguments and
  # the listing of the --source directory (or "WORKTREE" without one).
  cat > $T/bin/chezmoi <<'EOF'
  #!/bin/sh
  [ "$1" = source-path ] && { printf '%s\n' "$CHECKOUT"; exit 0; }
  src=""; prev=""
  for a in "$@"; do [ "$prev" = --source ] && src=$a; prev=$a; done
  printf 'ARGS %s\n' "$*" > "$LOG"
  printf 'TMPDIR %s\n' "$TMPDIR" >> "$LOG"
  if [ -n "$src" ]; then printf 'SOURCE %s\n' "$src" >> "$LOG"; ls -A "$src" >> "$LOG"; else echo WORKTREE >> "$LOG"; fi
  EOF
  chmod 755 $T/bin/chezmoi
  path=($T/bin /usr/bin /bin /opt/homebrew/bin)
  export LOG=$T/log
  source $FUNCS

  # origin: a bare repo whose main holds dot_testfile.
  git init -q --bare $T/origin.git
  git clone -q $T/origin.git $T/seed 2>/dev/null
  print hello > $T/seed/dot_testfile
  git -C $T/seed add dot_testfile && git -C $T/seed commit -q -m init && git -C $T/seed push -q origin main 2>/dev/null
  WANT=$(git -C $T/seed rev-parse HEAD)

  # --no-local: the checkout gets its own object files, so a forged object in it can never
  # alter origin's through a hard link.
  fresh() { rm -rf $T/co; git clone -q --no-local $T/origin.git $T/co 2>/dev/null; export CHECKOUT=$T/co; rm -f $LOG }
  applied_clone() { [[ -f $LOG ]] && grep -q '^SOURCE ' $LOG && grep -qx dot_testfile $LOG && ! grep -q "$1" $LOG }
  tmp_clean() { [[ ! -d $T/cache/chezmoi-apply || -z $(ls -A $T/cache/chezmoi-apply) ]] }

  fresh; chezmoi apply >/dev/null 2>&1
  if applied_clone NOPE && grep -q "^ARGS --source $T/cache/chezmoi-apply/run\..*/src apply$" $LOG \
     && grep -q "^TMPDIR $T/cache/chezmoi-apply/run\..*/tmp$" $LOG && tmp_clean; then
    _pass "a clean main equal to origin applies a fresh clone kept under the cache, with chezmoi's TMPDIR there"
  else _fail "clean main applies a fresh clone under the cache" "$(cat $LOG 2>/dev/null)"; fi
  fresh; chezmoi apply -v >/dev/null 2>&1
  applied_clone NOPE && grep -q -- ' apply -v$' $LOG && _pass "options after apply take the wrapper's path" || _fail "apply -v" "$(cat $LOG 2>/dev/null)"
  for form in "-v apply" "--progress auto apply" "--source $T/co apply" "-S $T/co update" "--color off init --apply"; do
    fresh; err=$(chezmoi ${=form} 2>&1 >/dev/null); rc=$?
    (( rc == 1 )) && [[ $err == *"put the subcommand first"* ]] && [[ ! -e $LOG ]] \
      && _pass "chezmoi $form is refused: subcommand first" || _fail "chezmoi $form is refused" "rc=$rc err=$err"
  done
  for form in "apply --source $T/co" "apply --source=$T/co" "apply -S$T/co" "apply -vS$T/co" "apply -nvc$T/x.toml" \
              "apply --config $T/x.toml" "update --working-tree $T/co"; do
    fresh; err=$(chezmoi ${=form} 2>&1 >/dev/null); rc=$?
    (( rc == 1 )) && [[ $err == *"the wrapper chooses the source"* ]] && [[ ! -e $LOG ]] \
      && _pass "chezmoi $form is refused" || _fail "chezmoi $form is refused" "rc=$rc err=$err"
  done
  for form in "init --apply" "init --apply=true" "init -a" "init -va" "init -av" "init -a=true" \
              "edit --apply x" "edit --apply=1 x"; do
    fresh; err=$(chezmoi ${=form} 2>&1 >/dev/null); rc=$?
    (( rc == 1 )) && [[ $err == *"--apply is refused"* ]] && [[ ! -e $LOG ]] \
      && _pass "chezmoi $form is refused" || _fail "chezmoi $form is refused" "rc=$rc err=$err"
  done
  fresh; chezmoi --version >/dev/null 2>&1; grep -q '^ARGS --version$' $LOG && _pass "an option-only command passes through" || _fail "--version" "$(cat $LOG 2>/dev/null)"
  fresh; chezmoi apply --dry-run --verbose >/dev/null 2>&1
  grep -q -- '--dry-run --verbose' $LOG 2>/dev/null && applied_clone NOPE && _pass "the dry-run preview takes the same path" || _fail "dry-run" "$(cat $LOG 2>/dev/null)"

  refuses() { # refuses <label> <expected reason text>: chezmoi apply returns 1, names it, runs nothing
    local err; err=$(chezmoi apply 2>&1 >/dev/null); local rc=$?
    if (( rc == 1 )) && [[ $err == *"$2"* ]] && [[ ! -e $LOG ]] && tmp_clean; then _pass "$1"
    else _fail "$1" "rc=$rc err=$err log=$(cat $LOG 2>/dev/null)"; fi
  }
  fresh; git -C $T/co switch -q -c other; refuses "another branch is refused" "not on main"
  fresh; print change >> $T/co/dot_testfile; refuses "an uncommitted change is refused" "uncommitted"
  fresh; print x > $T/co/newfile; refuses "an untracked file is refused" "uncommitted"
  fresh; git -C $T/co commit -q --allow-empty -m local; refuses "a local commit origin lacks is refused" "origin's main is"
  fresh; git -C $T/seed commit -q --allow-empty -m ahead && git -C $T/seed push -q origin main 2>/dev/null
  refuses "origin ahead of the checkout is refused" "origin's main is"
  WANT=$(git -C $T/seed rev-parse HEAD)

  # Planted content in a checkout that passes the precondition never reaches the source.
  fresh; print 'touch PWNED' > $T/co/run_evil.sh; print run_evil.sh >> $T/co/.git/info/exclude
  chezmoi apply >/dev/null 2>&1; applied_clone run_evil.sh && _pass "a run_ script hidden by .git/info/exclude is not applied" || _fail "excluded run_ script" "$(cat $LOG 2>/dev/null)"
  # mkevil: in the current checkout, a commit whose tree holds run_evil.sh; sets EVIL and EVILTREE.
  mkevil() {
    local blob; blob=$(print 'touch PWNED' | git -C $T/co hash-object -w --stdin) || return 1
    EVILTREE=$(printf '100644 blob %s\trun_evil.sh\n' $blob | git -C $T/co mktree) || return 1
    EVIL=$(git -C $T/co commit-tree -m evil $EVILTREE) || return 1
    [[ -n $EVIL && -n $EVILTREE ]]
  }
  fresh; if mkevil && git -C $T/co replace $WANT $EVIL; then
    chezmoi apply >/dev/null 2>&1; applied_clone run_evil.sh && _pass "a replacement ref for origin's commit is not applied" || _fail "replace ref" "$(cat $LOG 2>/dev/null)"
  else _fail "replace-ref fixture" "setup failed"; fi
  fresh; if mkevil && git -C $T/co update-ref refs/remotes/origin/main $EVIL \
       && [[ $(git -C $T/co rev-parse refs/remotes/origin/main) == $EVIL ]]; then
    chezmoi apply >/dev/null 2>&1; applied_clone run_evil.sh && _pass "a moved refs/remotes/origin/main is not applied" || _fail "moved remote ref" "$(cat $LOG 2>/dev/null)"
  else _fail "moved-ref fixture" "setup failed"; fi
  fresh; obj=$T/co/.git/objects/${WANT[1,2]}/${WANT[3,-1]}
  if mkevil && mkdir -p ${obj:h} && printf 'tree %s\nauthor x <x> 0 +0000\ncommitter x <x> 0 +0000\n\nforged\n' $EVILTREE \
       | /usr/bin/python3 -c 'import sys,zlib; d=sys.stdin.buffer.read(); sys.stdout.buffer.write(zlib.compress(b"commit %d\0" % len(d) + d))' > $obj \
       && [[ -s $obj ]]; then
    # Whether git reads the forged loose copy or the packed original decides what the checkout
    # looks like; either way the outcome must be safe. If it reads the forgery, the checkout no
    # longer matches its index and the wrapper refuses. If not, it applies the fresh clone.
    # Never the forged tree.
    chezmoi apply >/dev/null 2>&1; rc=$?
    if [[ $(git -C $T/co cat-file -p $WANT | tail -1) == forged ]]; then
      (( rc == 1 )) && [[ ! -e $LOG ]] && _pass "a forged object that git reads makes the wrapper refuse" \
        || _fail "forged object read by git" "rc=$rc log=$(cat $LOG 2>/dev/null)"
    else
      applied_clone run_evil.sh && _pass "a forged object git ignores leaves the fresh clone applied" \
        || _fail "forged object ignored by git" "$(cat $LOG 2>/dev/null)"
    fi
    [[ $(git -C $T/origin.git cat-file -p $WANT | tail -1) != forged ]] && _pass "origin's own object stays intact" \
      || _fail "origin's object" "forged through a hard link"
  else _fail "forged-object fixture" "setup failed"; fi

  fresh; print change >> $T/co/dot_testfile; chezmoi apply --dirty-ok >/dev/null 2>&1
  grep -qx WORKTREE $LOG 2>/dev/null && ! grep -q -- --dirty-ok $LOG && _pass "--dirty-ok applies the working tree and never reaches chezmoi" || _fail "--dirty-ok" "$(cat $LOG 2>/dev/null)"
  fresh; chezmoi status >/dev/null 2>&1; grep -q '^ARGS status$' $LOG && _pass "other subcommands pass through" || _fail "passthrough" "$(cat $LOG 2>/dev/null)"
  fresh; git -C $T/seed commit -q --allow-empty -m ahead2 && git -C $T/seed push -q origin main 2>/dev/null
  chezmoi update >/dev/null 2>&1
  grep -q '^ARGS --source .* apply$' $LOG 2>/dev/null && [[ $(git -C $T/co rev-parse HEAD) == $(git -C $T/seed rev-parse HEAD) ]] \
    && _pass "update fast-forwards, then applies a fresh clone" || _fail "update" "$(cat $LOG 2>/dev/null)"
  tmp_clean && _pass "no temporary clone is left behind" || _fail "temporary clones" "$(ls $T/tmp)"

  print "\npassed: $pass  failed: $fail"
  (( fail == 0 ))
  ```
  `chmod 755` it. If a fixture line does not behave as written on this git, fix the fixture (not the assertion) and say so in the report.
- [ ] **Step 2: Run** `./tests/chezmoi-wrapper.test.sh` — the wrapper cases FAIL (no wrapper yet: the stub is called directly).
- [ ] **Step 3: Implement.** Append to `dot_config/zsh/functions`:
  ```zsh
  # chezmoi apply and update deploy only origin's main (spec 2026-10-16, sandbox write boundary,
  # section 3). The checkout cannot prove what was reviewed: a sandboxed command can commit to
  # it, hide files from git status, add replace refs or forge objects. So the checkout must be a
  # clean main equal to origin's, and chezmoi reads a fresh clone of that commit instead of it.
  # --dirty-ok applies the working tree anyway, for a deliberate local change.
  # _chezmoi_short <token> <letters>: true when <token> is a single-dash option group that names
  # one of <letters> before a letter taking a value (c, D, o, S, W: the rest is that value).
  _chezmoi_short() {
    local t=${1#-} c
    [[ $1 == -[!-]* ]] || return 1
    while [[ -n $t ]]; do
      c=${t[1]}; t=${t[2,-1]}
      [[ $2 == *$c* ]] && return 0
      [[ $c == [cDoSW] ]] && return 1
    done
    return 1
  }
  chezmoi() {
    local -a args=("$@")
    local sub=${1:-} a
    # chezmoi takes global options before the subcommand, some with a value, and a parser that
    # misses one would read the value as the subcommand and let apply through. So a command
    # that names apply, update, init or edit must put the subcommand first.
    if [[ $sub == -* ]]; then
      if (( ${args[(Ie)apply]} || ${args[(Ie)update]} || ${args[(Ie)init]} || ${args[(Ie)edit]} )); then
        print -u2 "chezmoi: put the subcommand first, e.g. chezmoi apply -v"
        return 1
      fi
      command chezmoi "$@"; return
    fi
    case $sub in
      apply|update) ;;
      init|edit)
        # --apply in any spelling: --apply, --apply=<value>, or -a anywhere in a short-option group.
        for a in "${args[@]:1}"; do
          if [[ $a == --apply || $a == --apply=* ]] || _chezmoi_short "$a" a; then
            print -u2 "chezmoi: $sub --apply is refused; run chezmoi apply, which deploys origin's main"
            return 1
          fi
        done
        command chezmoi "$@"; return ;;
      *) command chezmoi "$@"; return ;;
    esac
    # Every git read below judges the real objects, never a replacement.
    local -x GIT_NO_REPLACE_OBJECTS=1
    if (( ${args[(Ie)--dirty-ok]} )); then
      command chezmoi "${(@)args:#--dirty-ok}"; return
    fi
    # An option that picks the source or the configuration would undo the choice below.
    for a in "${args[@]}"; do
      if [[ $a == (--source|--source=*|--working-tree|--working-tree=*|--config|--config=*) ]] \
         || _chezmoi_short "$a" SWc; then
        print -u2 "chezmoi: refusing $sub with $a: the wrapper chooses the source (--dirty-ok passes everything through)"
        return 1
      fi
    done
    local src st want head url tmp base
    src=$(command chezmoi source-path) || return
    if [[ $sub == update ]]; then
      git -C "$src" pull -q --ff-only || { print -u2 "chezmoi: git pull --ff-only failed in $src"; return 1 }
    fi
    [[ $(git -C "$src" symbolic-ref -q --short HEAD) == main ]] \
      || { print -u2 "chezmoi: refusing $sub: $src is not on main"; return 1 }
    st=$(git -C "$src" status --porcelain --untracked-files=all) || return
    if [[ -n $st ]]; then
      print -u2 "chezmoi: refusing $sub: $src has uncommitted or untracked changes:"
      print -u2 -r -- "$st"
      print -u2 "  (chezmoi $sub --dirty-ok applies the working tree anyway)"
      return 1
    fi
    want=$(git -C "$src" ls-remote origin refs/heads/main) || { print -u2 "chezmoi: refusing $sub: cannot read origin's main"; return 1 }
    want=${want%%$'\t'*}
    [[ $want =~ '^[0-9a-f]{40}([0-9a-f]{24})?$' ]] || { print -u2 "chezmoi: refusing $sub: origin has no main"; return 1 }
    head=$(git -C "$src" rev-parse HEAD) || return
    [[ $head == $want ]] || {
      print -u2 "chezmoi: refusing $sub: $src is at ${head[1,12]}, origin's main is ${want[1,12]}; pull or push first"
      return 1
    }
    url=$(git -C "$src" remote get-url origin) || return
    # The clone lives where the sandbox cannot write (~/.cache is outside its write set), and
    # chezmoi writes its scripts there too: nothing sandboxed can change them between the check
    # and the apply.
    base=${XDG_CACHE_HOME:-$HOME/.cache}/chezmoi-apply
    mkdir -p -m 700 "$base" && tmp=$(mktemp -d "$base/run.XXXXXX") || return
    {
      git clone -q --depth 1 --branch main --template= -- "$url" "$tmp/src" \
        || { print -u2 "chezmoi: cannot clone origin's main"; return 1 }
      [[ $(git -C "$tmp/src" rev-parse HEAD) == $want ]] \
        || { print -u2 "chezmoi: origin's main moved during the clone; run it again"; return 1 }
      print -u2 "chezmoi: applying origin's main ${want[1,12]} from a fresh clone"
      [[ $sub == update ]] && args[${args[(i)update]}]=apply
      mkdir -p "$tmp/tmp" && TMPDIR="$tmp/tmp" command chezmoi --source "$tmp/src" "${args[@]}"
    } always {
      rm -rf -- "$tmp"
    }
  }
  ```
  Note `st`, not `status`: `status` is a read-only special parameter in zsh.
- [ ] **Step 4: Run** `./tests/chezmoi-wrapper.test.sh` — every case PASSes. Also run `./tests/wt-functions.test.sh` and `./tests/zsh-config.test.sh` (they source the same file): totals unchanged.
- [ ] **Step 5: Report back.** The controller commits both files as "Apply only a fresh clone of origin's main", after checking `tests/chezmoi-wrapper.test.sh` is mode 100755.

---

### Task 7: The live suite and its documentation

**Depends on:** none

**Files:**
- Create: `tests/live-write-boundary.test.sh` (mode 755)
- Modify: `AGENTS.md` (the Testing table: one row)

- [ ] **Step 1: Write the suite.** Create `tests/live-write-boundary.test.sh`:
  ```bash
  #!/usr/bin/env bash
  # Run inside a fresh Claude sandbox after chezmoi apply. Tries to create a file in each place
  # the sandbox must not write (spec 2026-10-16, sandbox write boundary) and in each work place
  # it must still write; reports KEY=VALUE only and removes what it created.
  # test-requires: sandboxed, fresh-session  # measures the sandbox; unsandboxed every denial reads WRITABLE
  set -u
  fail=0
  stamp="zz-write-boundary-$$"
  # denied <key> <path>: creating <path> (a file, or a directory when it ends in /) must fail.
  denied() {
    local ok=1
    case $2 in */) mkdir "${2%/}" 2>/dev/null && { ok=0; rmdir "${2%/}"; } ;;
               *) ( : > "$2" ) 2>/dev/null && { ok=0; rm -f "$2"; } ;; esac
    if [ $ok = 1 ]; then echo "$1=DENIED"; else echo "$1=WRITABLE"; fail=$((fail + 1)); fi
  }
  # allowed <key> <path>: creating <path> must succeed; it is removed again.
  allowed() {
    case $2 in */) mkdir -p "${2%/}" 2>/dev/null && { echo "$1=WRITABLE"; rm -rf "${2%/}"; return; } ;;
               *) ( : > "$2" ) 2>/dev/null && { echo "$1=WRITABLE"; rm -f "$2"; return; } ;; esac
    echo "$1=DENIED"; fail=$((fail + 1))
  }
  V="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/MSB"
  denied local_bin "$HOME/.local/bin/$stamp"
  denied config "$HOME/.config/$stamp"
  denied config_zsh "$HOME/.config/zsh/$stamp"
  denied config_git "$HOME/.config/git/$stamp"
  denied config_mise "$HOME/.config/mise/$stamp"
  denied config_herdr "$HOME/.config/herdr/$stamp"
  denied vault_obsidian "$V/.obsidian/$stamp"
  # Fake git directories in each work root: the deny globs are path rules, so a mkdir'd .git
  # stands in for a real one (git init itself writes .git/config, which is denied).
  for root in "$HOME/Code" "$HOME/.local/share/chezmoi" "$HOME/Documents"; do
    k=$(basename "$root" | tr -c 'a-zA-Z0-9\n' '_')
    g="$root/$stamp/.git"
    if mkdir -p "$g/objects" "$g/refs/heads" "$g/modules/sub/worktrees/swt" "$g/worktrees/wt" 2>/dev/null; then
      denied "${k}_git_hooks" "$g/hooks/"
      denied "${k}_git_config" "$g/config"
      denied "${k}_git_config_worktree" "$g/config.worktree"
      denied "${k}_git_module_hooks" "$g/modules/sub/hooks/"
      denied "${k}_git_module_config" "$g/modules/sub/config"
      denied "${k}_git_module_config_worktree" "$g/modules/sub/config.worktree"
      denied "${k}_git_module_worktree_config" "$g/modules/sub/worktrees/swt/config.worktree"
      denied "${k}_git_worktree_config" "$g/worktrees/wt/config.worktree"
      allowed "${k}_git_objects" "$g/objects/$stamp"
      allowed "${k}_git_branch_named_config" "$g/refs/heads/config"
      allowed "${k}_git_branch_named_hooks" "$g/refs/heads/hooks"
      rm -rf "$root/$stamp"
    else
      echo "${k}_root=DENIED"; fail=$((fail + 1))
    fi
  done
  # Outside the work roots nothing changes: a git directory in TMPDIR keeps its config writable.
  tg="${TMPDIR:-/tmp}/$stamp/.git"
  if mkdir -p "$tg" 2>/dev/null; then allowed tmpdir_git_config "$tg/config"; rm -rf "${TMPDIR:-/tmp}/$stamp"
  else echo "tmpdir_root=DENIED"; fail=$((fail + 1)); fi
  # The chezmoi wrapper clones into ~/.cache/chezmoi-apply and points chezmoi's TMPDIR there:
  # the sandbox must not be able to touch that clone between the check and the apply.
  denied cache_chezmoi_apply "$HOME/.cache/chezmoi-apply/$stamp"
  denied cache "$HOME/.cache/$stamp"
  allowed code "$HOME/Code/$stamp"
  allowed chezmoi_source "$HOME/.local/share/chezmoi/$stamp"
  allowed documents "$HOME/Documents/$stamp"
  allowed vault_note "$V/$stamp.md"
  exit "$fail"
  ```
  `chmod 755` it.
- [ ] **Step 2: Check it is gated.** Run `./tests/run.sh live` and confirm `live-write-boundary` is listed as skipped with `needs: sandboxed, fresh-session`. Do not run it directly: it measures the deployed settings, which only Michael's `chezmoi apply` installs.
- [ ] **Step 3: Document it.** In `AGENTS.md`, extend the Testing table row that lists `live-agent-auth`, `live-agent-signing`, `live-credential-boundary` to include `live-write-boundary` (same needs, same reason: they measure the sandbox). Run `./tests/agent-instructions.test.sh` (AGENTS.md is not pinned there, but the suite must stay green).
- [ ] **Step 4: Report back.** The controller commits both files as "Add the live write-boundary suite", after checking the mode is 100755.
