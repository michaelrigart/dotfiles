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
