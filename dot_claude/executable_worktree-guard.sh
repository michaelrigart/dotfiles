#!/usr/bin/env bash
# PreToolUse(Bash) guard: wt worktrees are retired with `command wt-rm`, never raw git.
# Denies, in any command segment:
#   1. git worktree unlock                      (crosses the lifecycle lock)
#   2. git worktree remove with two or more forces (crosses it too)
#   3. git worktree remove of a literal absolute wt sibling (covers a hand-unlocked one)
# A correctness catch, not a security boundary: the Git lock is the boundary.
# An internal failure on a candidate denies with exit 2 (a text tool that errors counts, not
# only a missing one); a doubt about a parsed command still allows.
# Bypass: WT_GUARD=off anywhere in the command.
# Bash 3.2 compatible. Tests: tests/worktree-guard.test.sh
# Spec: docs/superpowers/specs/2026-10-01-herdr-wt-simplification-design.md §4
# Runs outside the sandbox, so it resolves nothing a sandboxed command can write (spec
# 2026-10-16, sandbox write boundary). PINNED_PATH is for the suites only.
PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH
set -uo pipefail
set -f

allow() { exit 0; }
fail_closed() { printf '%s\n' "$1" >&2; exit 2; }
deny() {
  printf '%s' "$1" | jq -Rs \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}' \
    2>/dev/null || fail_closed "$1"
  exit 0
}

# ere_match <ERE> <text>: 0 when the text matches, 1 when it does not, 2 when grep itself failed.
# A grep error (status 2 or more) is no match nobody checked, so callers refuse it. grep reads
# all its input (no -q), so a match can never SIGPIPE the printf and trip pipefail.
ere_match() {
  local st
  printf '%s' "$2" | grep -E -- "$1" >/dev/null
  st=("${PIPESTATUS[@]}")
  [ "${st[0]}" -eq 0 ] || return 2
  case "${st[1]}" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

payload=$(cat)
case "$payload" in *worktree[[:space:]\\]*) ;; *) allow ;; esac
command -v jq >/dev/null 2>&1 || fail_closed "Worktree guard: jq is missing, so this worktree command is refused."
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || fail_closed "Worktree guard: this command's payload could not be read, so it is refused."
[ -n "$cmd" ] && [ "$cmd" != null ] || allow
case "$cmd" in *WT_GUARD=off*) allow ;; esac
verb_re='worktree([[:space:]]|\\)+(remove|unlock)'
[[ $cmd =~ $verb_re ]] || allow

REMEDY="Retire a wt worktree with:

    command wt-rm <branch>

(\`command\` matters: it reaches the PATH wrapper, which loads the full lifecycle in a
non-interactive shell.) A worktree owned by another tool goes through that tool's own
lifecycle. For a deliberate manual reconciliation, re-run with WT_GUARD=off."

NL=$'\n'; TAB=$'\t'
sq="'"
# A git option's argument: one word whose first unit is not "-", where a unit is a
# plain char or a complete quoted string (a double-quoted one may hold backslash escapes), so a quoted value never ends the word early.
dq='"([^"\\]|\\.)*"'
optarg="(([^[:space:]\"$sq-]|$dq|$sq[^$sq]*$sq)([^[:space:]\"$sq]|$dq|$sq[^$sq]*$sq)*)"
prefix_re='^[[:space:]]*((if|while|until|do|then|else|elif|time|command|!|\{|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|sudo)[[:space:]]+)*(/[^[:space:]]*/)?git([[:space:]]+-[^[:space:]]+([[:space:]]+'"$optarg"')?)*[[:space:]]+worktree[[:space:]]+'

# sibling_of <abs-target> — print "<repo-dir> <slug>" when the target is a wt sibling.
sibling_of() {
  local target=$1 parent base acc="" rest seg
  [ -d "$target" ] || return 1
  parent=${target%/*}; [ -n "$parent" ] || parent=/
  base=${target##*/}; rest=$base
  while [ "${rest#*-}" != "$rest" ]; do
    seg=${rest%%-*}
    if [ -n "$acc" ]; then acc="$acc-$seg"; else acc=$seg; fi
    rest=${rest#*-}
    if [ -d "$parent/$acc" ] && [ -e "$parent/$acc/.git" ]; then
      printf '%s %s\n' "$parent/$acc" "${base#"$acc"-}"
      return 0
    fi
  done
  return 1
}

# target_of <args> — the literal absolute target, quote-aware, or nothing.
target_of() {
  local tok rest after target="" quoted=""
  for tok in $1; do
    case "$tok" in -*) continue ;; esac
    case "$tok" in
      \"*|\'*)
        q=${tok:0:1}; rest=${tok#?}
        case "$rest" in
          *"$q"*) target=${rest%%"$q"*}; after=${rest#*"$q"}
                  case "$after" in ""|[\;\&\|\)\<\>]*) quoted=1 ;; *) return 0 ;; esac ;;
          *) return 0 ;;
        esac ;;
      *) target=$tok ;;
    esac
    break
  done
  case "$target" in /*) ;; *) return 0 ;; esac
  [ -z "$quoted" ] && target=${target%%[;&|)<>]*}
  printf '%s\n' "${target%/}"
}

check() {
  local seg=$1 sub args force=0 tok f target sib
  seg=${seg%%"$NL"*}   # a quoted string may span lines; only its first line can be a command
  case "$seg" in *worktree*) ;; *) return 0 ;; esac
  ere_match "${prefix_re}(remove|unlock)([[:space:]]|\$)" "$seg"
  case $? in
    0) ;;
    1) return 0 ;;
    *) fail_closed "Worktree guard: a text check (grep) could not run, so this worktree command is refused." ;;
  esac
  sub=$(printf '%s' "$seg" | sed -E "s#${prefix_re}##") \
    || fail_closed "Worktree guard: a text check (sed) could not run, so this worktree command is refused."
  case "$sub" in
    unlock*) deny "\`git worktree unlock\` crosses the wt lifecycle lock.

$REMEDY" ;;
  esac
  args=${sub#remove}
  for tok in $args; do
    case "$tok" in
      --force) force=$((force + 1)) ;;
      --*) ;;
      -*) f=${tok//[!f]/}; force=$((force + ${#f})) ;;
    esac
  done
  [ "$force" -ge 2 ] && deny "\`git worktree remove\` forced twice crosses the wt lifecycle lock.

$REMEDY"
  target=$(target_of "$args")
  [ -n "$target" ] || return 0
  sib=$(sibling_of "$target") || return 0
  deny "Raw \`git worktree remove\` on a wt-managed worktree.

$target is the wt sibling of the repository at ${sib%% *}. Raw removal skips Herdr
workspace closure and the project teardown hook, and live processes write the path back.
The directory slug is \"${sib#* }\"; a slug maps '/' to '-', so use the branch name.

$REMEDY"
}

# Quote-aware split into command segments. Quoted text, comments and heredoc bodies
# never start a segment.
seg="" quote="" pending="" body="" cont=""
while IFS= read -r line || [ -n "$line" ]; do
  if [ -n "$body" ]; then
    t=$line
    while [ "${t#"$TAB"}" != "$t" ]; do t=${t#"$TAB"}; done
    [ "$t" = "$body" ] && body=""
    continue
  fi
  i=0; n=${#line}
  while [ "$i" -lt "$n" ]; do
    c=${line:$i:1}
    if [ -n "$quote" ]; then
      seg="$seg$c"
      if [ "$c" = "$quote" ]; then quote=""
      elif [ "$c" = '\' ] && [ "$quote" = '"' ]; then i=$((i + 1)); seg="$seg${line:$i:1}"; fi
      i=$((i + 1)); continue
    fi
    case "$c" in
      \'|\") quote=$c; seg="$seg$c" ;;
      \\)
        if [ $((i + 1)) -ge "$n" ]; then cont=1   # backslash-newline joins the next line
        else i=$((i + 1)); seg="$seg$c${line:$i:1}"; fi ;;
      \#) case "$seg" in ''|*[[:space:]]) break ;; *) seg="$seg$c" ;; esac ;;
      \;|\||\&|\(|\)) check "$seg"; seg="" ;;
      \<)
        if [ "${line:$((i + 1)):2}" = '<<' ]; then
          seg="$seg<<<"; i=$((i + 2))            # a here-string, never a heredoc
        elif [ "${line:$((i + 1)):1}" = '<' ]; then
          rest=${line:$((i + 2))}; rest=${rest#-}
          rest=${rest#"${rest%%[![:space:]]*}"}
          d=${rest%%[[:space:];|&<>()]*}; d=${d//\'/}; d=${d//\"/}; d=${d//\\/}
          [ -n "$d" ] && pending=$d
          seg="$seg<<"; i=$((i + 1))
        else
          seg="$seg$c"
        fi ;;
      *) seg="$seg$c" ;;
    esac
    i=$((i + 1))
  done
  if [ -n "$quote" ]; then
    seg="$seg
"
  elif [ -n "$cont" ]; then
    cont=""
  else
    check "$seg"; seg=""
    if [ -n "$pending" ]; then body=$pending; pending=""; fi
  fi
done <<EOF
$cmd
EOF
check "$seg"
allow
