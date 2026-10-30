#!/usr/bin/env bash
# Run inside a fresh Claude sandbox after chezmoi apply. Tries to create a file in each place
# the sandbox must not write (specs 2026-10-16, sandbox write boundary, and 2026-10-30, git
# configuration and .git where no repository may be) and in each work place it must still write;
# reports KEY=VALUE only and removes what it created.
# test-requires: sandboxed, fresh-session  # measures the sandbox; unsandboxed every denial reads WRITABLE
set -u
fail=0
stamp="zz-write-boundary-$$"
# Every path the suite may create; the trap removes them on any exit and reports leftovers.
probes=("$HOME/.cache/$stamp")
# The behaviour probe's scratch directory in TMPDIR; empty until it exists.
TB=
cleanup() {
  local rc=$? p
  trap - EXIT INT TERM
  # The behaviour repository goes back to TMPDIR first: rm -rf cannot delete a denied .git/config in place.
  if [ -n "$TB" ] && [ -d "$HOME/Code/$stamp-b/r" ]; then mv "$HOME/Code/$stamp-b/r" "$TB/r-back" 2>/dev/null; fi
  for p in "${probes[@]}"; do rm -rf "$p" 2>/dev/null; done
  for p in "${probes[@]}"; do
    if [ -e "$p" ] || [ -L "$p" ]; then echo "cleanup=LEFT"; fail=$((fail + 1)); break; fi
  done
  if [ "$fail" = 0 ] && [ "$rc" != 0 ]; then exit "$rc"; fi
  exit "$fail"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# try <d|f> <path>: create it (never over an existing file) and remove it again on success.
try() {
  if [ "$1" = d ]; then
    mkdir "$2" 2>/dev/null && { rmdir "$2" 2>/dev/null; return 0; }
  else
    ( set -C; : > "$2" ) 2>/dev/null && { rm -f "$2" 2>/dev/null; return 0; }
  fi
  return 1
}
# prepare <key> <path>: sets $kind and $target; returns 1 after reporting ABSENT (missing parent)
# or EXISTS (the probe would touch something real). A directory probe whose target already
# exists is replaced by a file inside it, so the real directory is never removed.
prepare() {
  target=$2; kind=f
  case $target in */) target=${target%/}; if [ -d "$target" ]; then target="$target/$stamp"; else kind=d; fi ;; esac
  if [ ! -d "$(dirname "$target")" ]; then echo "$1=ABSENT"; fail=$((fail + 1)); return 1; fi
  if [ -e "$target" ] || [ -L "$target" ]; then echo "$1=EXISTS"; fail=$((fail + 1)); return 1; fi
  probes+=("$target")
}
# denied <key> <path>: creating <path> (a file, or a directory when it ends in /) must fail.
denied() {
  local kind target
  prepare "$1" "$2" || return 0
  if try "$kind" "$target"; then echo "$1=WRITABLE"; fail=$((fail + 1)); else echo "$1=DENIED"; fi
}
# allowed <key> <path>: creating <path> must succeed; it is removed again.
allowed() {
  local kind target
  prepare "$1" "$2" || return 0
  if try "$kind" "$target"; then echo "$1=WRITABLE"; else echo "$1=DENIED"; fail=$((fail + 1)); fi
}
# denied_existing <key> <path>: <path> must be an existing file that cannot be opened for append.
# The open writes nothing. A missing file reads ABSENT, which counts as a failure.
denied_existing() {
  if [ ! -f "$2" ]; then echo "$1=ABSENT"; fail=$((fail + 1)); return 0; fi
  if ( : >> "$2" ) 2>/dev/null; then echo "$1=WRITABLE"; fail=$((fail + 1)); else echo "$1=DENIED"; fi
}
# allowed_off_base <key> <path>: a file in .claude/commands or .claude/agents, or the git config in
# TMPDIR (tmpdir_git_config).
# Claude Code's own sandbox rules deny those under the session's working directory (commands and
# agents are measured; a session based under TMPDIR would also cover tmpdir_git_config), which are not
# this spec's rules: report SKIPPED there.
# tests/run.sh exports the directory it was started from; run directly, it is pwd.
# An unenterable RUN_SH_START_DIR falls back to pwd; an empty base would make "$base"/* match every
# path and skip each probe silently, so that counts as a failure.
base=$(cd "${RUN_SH_START_DIR:-.}" 2>/dev/null && pwd -P) || base=$(pwd -P 2>/dev/null) || base=
if [ -z "$base" ]; then echo "base_dir=UNKNOWN"; fail=$((fail + 1)); fi
# git ignoring the global and system configuration (the chezmoi top-level probe and the behaviour probe).
gi() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
gc() { gi -c user.name=t -c user.email=t@t "$@"; }
allowed_off_base() {
  local d
  d=$(cd "$(dirname "$2")" 2>/dev/null && pwd -P)
  case "${d:-/}/$(basename "$2")" in
    "$base"/*) echo "$1=SKIPPED"; return 0 ;;
  esac
  allowed "$1" "$2"
}
V="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/MSB"
denied local_bin "$HOME/.local/bin/$stamp"
denied config "$HOME/.config/$stamp"
denied config_zsh "$HOME/.config/zsh/$stamp"
denied config_git "$HOME/.config/git/$stamp"
denied config_mise "$HOME/.config/mise/$stamp"
denied config_herdr "$HOME/.config/herdr/$stamp"
denied vault_obsidian "$V/.obsidian/$stamp"
# Fake repositories at depth 2 in the three roots that may hold one (~/Code, the chezmoi checkout,
# ~/Documents): the deny globs are path rules, so a mkdir'd .git stands in for a real one. Hooks and git
# configuration (config*, commondir, in the main directory, linked worktrees and submodules) are denied;
# objects, refs, the index and a worktree's gitdir stay writable. The vault holds no repository: it gets
# no .git fixture, and a .git at any depth there is denied (probed two levels below the vault root, as a
# directory in <stamp>/vdir and as a file in <stamp>/org). The vault root is probed above Documents/MSB,
# away from Obsidian. A repository's git directory inside a linked worktree's submodule
# (.git/worktrees/wt/modules/sub) is probed too: config, commondir and hooks are denied there.
# Two different families of deny follow, and they stop different things. The .git-file denies stop a
# .git entry from pointing git at a directory the sandbox wrote (the root tops, the vault, harness
# worktrees). The HEAD denies stop a fake bare repository from forming at a root's top level, which
# Starship would walk up into although git's safe.bareRepository refuses it; they are probed below.
# Agent configuration a later session would load (.claude/settings*.json, .mcp.json, .codex) is denied
# only at depth 0-2 under a root, where sessions start: probed in a repository two levels down
# (<root>/<stamp>/arepo). Deeper it stays writable, so a node_modules package that ships one (resolve
# ships .claude/settings.local.json) keeps npm ci working: probed four levels down. .claude/skills,
# commands and agents stay writable. A Claude Code harness worktree (<repo>/.claude/worktrees/<name>)
# loads its own agent configuration four or five levels down: the fixed-depth worktree forms deny it,
# probed at <root>/<stamp>/arepo/.claude/worktrees/wt1/.claude/settings.json, and they deny its .git
# file, probed at <root>/<stamp>/arepo/.claude/worktrees/wt1/.git. .codex cannot be created, so its
# directory is the probe and .codex/** is not measurable from inside the sandbox.
for root in "$HOME/Code" "$HOME/.local/share/chezmoi" "$HOME/Documents" \
            "$HOME/Library/Mobile Documents/iCloud~md~obsidian"; do
  k=$(basename "$root" | tr -c 'a-zA-Z0-9\n' '_')
  b="$root/$stamp"
  r="$b/org/repo"
  g="$r/.git"
  m="$b/org/mv"
  ar="$b/arepo"
  nm="$ar/node_modules/pkg"
  vault=0
  case $root in *iCloud~md~obsidian) vault=1 ;; esac
  probes+=("$b")
  dirs=("$m/plain/hooks" "$r/.claude/skills" "$r/.claude/commands" "$r/.claude/agents" \
        "$ar/.claude" "$nm/.claude" "$ar/.claude/worktrees/wt1/.claude")
  if [ "$vault" = 0 ]; then
    dirs+=("$g/objects" "$g/refs/heads" "$g/modules/sub/worktrees/swt" "$g/worktrees/wt/modules/sub" "$b/plain")
  else
    dirs+=("$b/vdir")
  fi
  if mkdir -p "${dirs[@]}" 2>/dev/null; then
    if [ "$vault" = 1 ]; then
      # .git-file/.git-directory denies: both two levels below the vault root (<stamp>/vdir, <stamp>/org).
      denied vault_git_dir "$b/vdir/.git/"
      denied vault_git_file "$b/org/.git"
      # Fake-bare-repository denies (HEAD, either case), in the directory of the file above.
      denied vault_head "$b/org/HEAD"
      denied vault_head_lower "$b/org/head"
    else
      denied "${k}_git_hooks" "$g/hooks/"
      denied "${k}_git_config" "$g/config"
      denied "${k}_git_config_lock" "$g/config.lock"
      denied "${k}_git_config_worktree" "$g/config.worktree"
      denied "${k}_git_commondir" "$g/commondir"
      denied "${k}_git_worktree_config" "$g/worktrees/wt/config.worktree"
      denied "${k}_git_worktree_commondir" "$g/worktrees/wt/commondir"
      allowed "${k}_git_worktree_gitdir" "$g/worktrees/wt/gitdir"
      denied "${k}_git_module_hooks" "$g/modules/sub/hooks/"
      denied "${k}_git_module_config" "$g/modules/sub/config"
      denied "${k}_git_module_commondir" "$g/modules/sub/commondir"
      denied "${k}_git_module_config_worktree" "$g/modules/sub/config.worktree"
      denied "${k}_git_module_worktree_config" "$g/modules/sub/worktrees/swt/config.worktree"
      denied "${k}_git_worktree_module_config" "$g/worktrees/wt/modules/sub/config"
      denied "${k}_git_worktree_module_commondir" "$g/worktrees/wt/modules/sub/commondir"
      denied "${k}_git_worktree_module_hooks" "$g/worktrees/wt/modules/sub/hooks/"
      allowed "${k}_git_objects" "$g/objects/$stamp"
      allowed "${k}_git_index" "$g/index"
      allowed "${k}_git_branch_named_config" "$g/refs/heads/config"
      allowed "${k}_git_branch_named_hooks" "$g/refs/heads/hooks"
    fi
    denied "${k}_claude_settings" "$ar/.claude/settings.json"
    denied "${k}_claude_settings_local" "$ar/.claude/settings.local.json"
    denied "${k}_mcp_json" "$ar/.mcp.json"
    denied "${k}_codex_dir" "$ar/.codex/"
    denied "${k}_harness_worktree_claude_settings" "$ar/.claude/worktrees/wt1/.claude/settings.json"
    denied "${k}_harness_worktree_git_file" "$ar/.claude/worktrees/wt1/.git"
    allowed "${k}_node_modules_claude_settings_local_writable" "$nm/.claude/settings.local.json"
    allowed "${k}_claude_skills_writable" "$r/.claude/skills/$stamp.md"
    allowed_off_base "${k}_claude_commands_writable" "$r/.claude/commands/$stamp.md"
    allowed_off_base "${k}_claude_agents_writable" "$r/.claude/agents/$stamp.md"
    # Fake-bare-repository denies at the organisation level: <stamp> stands for ~/Code/<Org>, so the
    # suite's own directory is probed and no real organisation directory is touched.
    if [ "$root" = "$HOME/Code" ]; then
      denied code_org_head "$b/HEAD"
      denied code_org_head_lower "$b/head"
    fi
    # A directory holding hooks/ under a plain name, renamed to .git. Path rules see only the two
    # ends of a rename, so outside the vault this reads WRITABLE by design: the same class as
    # core.hooksPath, which Michael accepted. In the vault it reads DENIED, because the vault denies a
    # .git at any depth, including the rename's target. Informational: the # prefix keeps it out of
    # tests/run.sh's count and the exit.
    # It is renamed back, because the **/.git/hooks deny would otherwise stop rm -rf from removing it.
    if mv "$m/plain" "$m/.git" 2>/dev/null; then v=WRITABLE; mv "$m/.git" "$m/plain" 2>/dev/null; else v=DENIED; fi
    echo "# info ${k}_git_rename_dir=$v (outside the vault WRITABLE is accepted: a rename is checked only at its two ends; in the vault DENIED: no .git at any depth)"
    # A .git file in a plain directory two levels down: path rules cannot tell it from a .git directory,
    # so it reads WRITABLE outside the vault. Informational, like the rename probe (spec Residuals).
    if [ "$vault" = 0 ]; then
      if [ ! -d "$b/plain" ]; then v=ABSENT
      elif ( set -C; : > "$b/plain/.git" ) 2>/dev/null; then v=WRITABLE; rm -f "$b/plain/.git" 2>/dev/null
      else v=DENIED; fi
      echo "# info ${k}_git_file_plain_dir=$v (residual: path rules cannot tell a .git file from a .git directory)"
    fi
  else
    echo "${k}_root=DENIED"; fail=$((fail + 1))
  fi
  rm -rf "${root:?}/${stamp:?}" 2>/dev/null
done
# The agent configuration directly under a work root (~/Code/.claude and ~/Documents/.claude exist).
denied code_root_claude_settings "$HOME/Code/.claude/settings.json"
denied documents_root_claude_settings "$HOME/Documents/.claude/settings.json"
# Neither ~/Code nor ~/Documents is a repository. Two families of deny cover their top level:
# - .git-file denies: a .git file there would pull every directory below it into a repository whose
#   configuration the sandbox wrote (git itself would follow it).
denied code_root_git_file "$HOME/Code/.git"
denied documents_root_git_file "$HOME/Documents/.git"
# - fake-bare-repository denies: a directory holding HEAD, objects/ and refs/ is a bare repository to
#   Starship, which walks up from the prompt's directory and ignores safe.bareRepository. Denying HEAD
#   (either case: the volume is case-insensitive) stops the directory forming. Real repositories keep
#   HEAD inside .git. The vault and the organisation level are probed in the fixture loop.
denied code_root_head "$HOME/Code/HEAD"
denied code_root_head_lower "$HOME/Code/head"
denied documents_root_head "$HOME/Documents/HEAD"
denied documents_root_head_lower "$HOME/Documents/head"
# The chezmoi checkout's own top-level .git.
cg="$HOME/.local/share/chezmoi/.git"
denied chezmoi_top_git_hooks "$cg/hooks/"
denied_existing chezmoi_top_git_config "$cg/config"
if [ -d "$cg/modules/x" ]; then
  denied chezmoi_top_git_module_hooks "$cg/modules/x/hooks/"
else
  if [ -d "$cg/modules" ]; then probes+=("$cg/modules/x"); else probes+=("$cg/modules"); fi
  if mkdir -p "$cg/modules/x" 2>/dev/null; then
    denied chezmoi_top_git_module_hooks "$cg/modules/x/hooks/"
  else
    # Claude Code's own rule also refuses creating .git/modules in the session repository. Started in a
    # harness worktree of the checkout, the session repository's git directory is the checkout's .git
    # (the common directory of the base), which is not under the base.
    common=$(cd "$base" 2>/dev/null && d=$(gi rev-parse --git-common-dir 2>/dev/null) && cd "$d" 2>/dev/null && pwd -P)
    cgreal=$(cd "$cg" 2>/dev/null && pwd -P)
    case "$cg" in
      "$base"/*) echo "chezmoi_top_git_module_hooks=SKIPPED" ;;
      *) if [ -n "$common" ] && [ "$common" = "$cgreal" ]; then echo "chezmoi_top_git_module_hooks=SKIPPED"
         else echo "chezmoi_top_git_module_hooks=ABSENT"; fail=$((fail + 1)); fi ;;
    esac
  fi
fi
# Outside the work roots nothing changes: a git directory in TMPDIR keeps its config writable.
tg="${TMPDIR:-/tmp}/$stamp/.git"
probes+=("${TMPDIR:-/tmp}/$stamp")
if mkdir -p "$tg" 2>/dev/null; then allowed_off_base tmpdir_git_config "$tg/config"
else echo "tmpdir_root=DENIED"; fail=$((fail + 1)); fi
rm -rf "${TMPDIR:-/tmp}/${stamp:?}" 2>/dev/null
# The chezmoi wrapper clones under ~/.cache and points chezmoi's TMPDIR there: the sandbox must
# not be able to write anywhere in ~/.cache between the check and the apply.
denied cache "$HOME/.cache/$stamp"
allowed code "$HOME/Code/$stamp"
allowed chezmoi_source "$HOME/.local/share/chezmoi/$stamp"
allowed documents "$HOME/Documents/$stamp"
allowed vault_note "$V/$stamp.md"
# Behaviour: a repository built in TMPDIR with a bare remote, moved under ~/Code/<stamp>-b/. There a
# commit works, git config and git worktree add are refused, and the upstream-setting push records
# no upstream. The git calls ignore the global and system configuration. A setup failure stops the
# probe: without the repository every denial probe below would read DENIED.
R="$HOME/Code/$stamp-b/r"
behaviour_setup() {
  TB=$(mktemp -d "${TMPDIR:-/tmp}/$stamp-b.XXXXXX") || return 1
  probes+=("$TB" "$HOME/Code/$stamp-b")
  gi init -q -b main "$TB/r" && gi init -q --bare "$TB/origin.git" \
    && gi -C "$TB/r" remote add origin "$TB/origin.git" \
    && gc -C "$TB/r" commit -q --allow-empty -m init \
    && gi -C "$TB/r" push -q origin main \
    && mkdir -p "$HOME/Code/$stamp-b" && mv "$TB/r" "$R" && [ -f "$R/.git/config" ]
}
if behaviour_setup >/dev/null 2>&1; then
  if gc -C "$R" commit -q --allow-empty -m probe >/dev/null 2>&1; then echo "behaviour_commit=OK"
  else echo "behaviour_commit=FAIL"; fail=$((fail + 1)); fi
  if gi -C "$R" config probe.key 1 >/dev/null 2>&1; then echo "behaviour_config=WRITABLE"; fail=$((fail + 1))
  else echo "behaviour_config=DENIED"; fi
  if gi -C "$R" push -q -u origin HEAD:refs/heads/b1 >/dev/null 2>&1 \
     && gi --git-dir="$TB/origin.git" rev-parse --verify -q refs/heads/b1 >/dev/null 2>&1 \
     && [ -z "$(gi -C "$R" config branch.main.merge 2>/dev/null)" ]; then echo "behaviour_push_u=OK"
  else echo "behaviour_push_u=FAIL"; fail=$((fail + 1)); fi
  if gi -C "$R" worktree add -q "$HOME/Code/$stamp-b/wt" -b wtb >/dev/null 2>&1; then
    echo "behaviour_worktree_add=WRITABLE"; fail=$((fail + 1))
  else echo "behaviour_worktree_add=DENIED"; fi
  if ( : >> "$R/.git/CONFIG" ) 2>/dev/null; then echo "behaviour_case_config=WRITABLE"; fail=$((fail + 1))
  else echo "behaviour_case_config=DENIED"; fi
  denied behaviour_case_commondir "$R/.git/COMMONDIR"
else
  echo "behaviour_setup=FAIL"; fail=$((fail + 1))
fi
exit "$fail"
