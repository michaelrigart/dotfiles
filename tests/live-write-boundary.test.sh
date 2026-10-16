#!/usr/bin/env bash
# Run inside a fresh Claude sandbox after chezmoi apply. Tries to create a file in each place
# the sandbox must not write (spec 2026-10-16, sandbox write boundary) and in each work place
# it must still write; reports KEY=VALUE only and removes what it created.
# test-requires: sandboxed, fresh-session  # measures the sandbox; unsandboxed every denial reads WRITABLE
set -u
fail=0
stamp="zz-write-boundary-$$"
# Every path the suite may create; the trap removes them on any exit and reports leftovers.
probes=("$HOME/.cache/$stamp")
cleanup() {
  local rc=$? p
  trap - EXIT INT TERM
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
# allowed_cfg <key> <path>: a git config file. Claude Code's own sandbox rule denies .git/config under
# the working directory (allowGitConfig stays unset), which is not this spec's rule: skip those.
cwd=$(pwd -P)
allowed_cfg() {
  local d
  d=$(cd "$(dirname "$2")" 2>/dev/null && pwd -P)
  case "${d:-/}/$(basename "$2")" in
    "$cwd"/*) echo "$1=SKIPPED_CWD"; return 0 ;;
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
# Fake repositories at depth 2 in each work root (the layout real repositories have): the deny
# globs are path rules, so a mkdir'd .git stands in for a real one. Only hooks are denied; git
# configuration files stay writable. The vault root is probed above Documents/MSB, away from Obsidian.
for root in "$HOME/Code" "$HOME/.local/share/chezmoi" "$HOME/Documents" \
            "$HOME/Library/Mobile Documents/iCloud~md~obsidian"; do
  k=$(basename "$root" | tr -c 'a-zA-Z0-9\n' '_')
  b="$root/$stamp"
  r="$b/org/repo"
  g="$r/.git"
  m="$b/org/mv"
  probes+=("$b")
  if mkdir -p "$g/objects" "$g/refs/heads" "$g/modules/sub/worktrees/swt" "$g/worktrees/wt" \
              "$m/plain/hooks" 2>/dev/null; then
    denied "${k}_git_hooks" "$g/hooks/"
    allowed_cfg "${k}_git_config_writable" "$g/config"
    allowed_cfg "${k}_git_config_worktree_writable" "$g/config.worktree"
    denied "${k}_git_module_hooks" "$g/modules/sub/hooks/"
    allowed_cfg "${k}_git_module_config_writable" "$g/modules/sub/config"
    allowed_cfg "${k}_git_module_config_worktree_writable" "$g/modules/sub/config.worktree"
    allowed_cfg "${k}_git_module_worktree_config_writable" "$g/modules/sub/worktrees/swt/config.worktree"
    allowed_cfg "${k}_git_worktree_config_writable" "$g/worktrees/wt/config.worktree"
    allowed "${k}_git_objects" "$g/objects/$stamp"
    allowed "${k}_git_index" "$g/index"
    allowed "${k}_git_branch_named_config" "$g/refs/heads/config"
    allowed "${k}_git_branch_named_hooks" "$g/refs/heads/hooks"
    # A directory holding hooks/ under a plain name, renamed to .git, must be refused as well.
    if mv "$m/plain" "$m/.git" 2>/dev/null; then
      echo "${k}_git_rename_dir=WRITABLE"; fail=$((fail + 1))
    else
      echo "${k}_git_rename_dir=DENIED"
    fi
  else
    echo "${k}_root=DENIED"; fail=$((fail + 1))
  fi
  rm -rf "${root:?}/${stamp:?}" 2>/dev/null
done
# The chezmoi checkout's own top-level .git.
cg="$HOME/.local/share/chezmoi/.git"
denied chezmoi_top_git_hooks "$cg/hooks/"
if [ -d "$cg/modules/x" ]; then
  denied chezmoi_top_git_module_hooks "$cg/modules/x/hooks/"
else
  if [ -d "$cg/modules" ]; then probes+=("$cg/modules/x"); else probes+=("$cg/modules"); fi
  if mkdir -p "$cg/modules/x" 2>/dev/null; then
    denied chezmoi_top_git_module_hooks "$cg/modules/x/hooks/"
  else
    echo "chezmoi_top_git_module_hooks=ABSENT"; fail=$((fail + 1))
  fi
fi
# Outside the work roots nothing changes: a git directory in TMPDIR keeps its config writable.
tg="${TMPDIR:-/tmp}/$stamp/.git"
probes+=("${TMPDIR:-/tmp}/$stamp")
if mkdir -p "$tg" 2>/dev/null; then allowed_cfg tmpdir_git_config "$tg/config"
else echo "tmpdir_root=DENIED"; fail=$((fail + 1)); fi
rm -rf "${TMPDIR:-/tmp}/${stamp:?}" 2>/dev/null
# The chezmoi wrapper clones under ~/.cache and points chezmoi's TMPDIR there: the sandbox must
# not be able to write anywhere in ~/.cache between the check and the apply.
denied cache "$HOME/.cache/$stamp"
allowed code "$HOME/Code/$stamp"
allowed chezmoi_source "$HOME/.local/share/chezmoi/$stamp"
allowed documents "$HOME/Documents/$stamp"
allowed vault_note "$V/$stamp.md"
exit "$fail"
