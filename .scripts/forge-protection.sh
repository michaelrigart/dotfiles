#!/usr/bin/env bash
# Read-only check that every repository's default branch is in the protection state the forge
# push-protection spec asks for. Walks the dotfiles checkout and ~/Code/*/*, reads each
# checkout's push URL for `origin`, asks the forge (GET calls only) and prints one row per
# normalized remote. Never writes to a forge: the commands that reach the target state are
# printed for Michael to run. Bash 3.2 compatible; needs git and jq.
#
# Usage: forge-protection.sh check | --help
#
# Inputs: HOME (the walk and ~/.config/forge-protection/exceptions, one remote URL per line,
#   `#` and blank lines skipped), PATH, FORGE_PROTECTION_TIMEOUT (seconds per forge call,
#   default 20).
#
# Rows: ok | drift (with the command or click path that fixes it) | unreadable (with the
#   reason) | excepted (listed in the exceptions file, not queried).
# Exit: 0 only when every row is ok or excepted; 1 when any row is drift or unreadable;
#   2 on usage, or when git or jq is missing.
# The output names repositories: never commit it or paste it into a tracked file.
set -u

LIMIT=${FORGE_PROTECTION_TIMEOUT:-20}
case "$LIMIT" in ''|*[!0-9]*) LIMIT=20 ;; esac
NL=$'\n'
N_OK=0; N_DRIFT=0; N_UNREADABLE=0; N_EXCEPTED=0
FC_OUT=; FC_ERR=; FC_RC=0
EXC=

usage() {
  cat <<'EOF'
Usage: forge-protection.sh check
  Read-only: asks each forge (GET only) whether the default branch of every checkout
  under ~/.local/share/chezmoi and ~/Code/*/* is in the target state, and prints one row
  per remote. Exit 0 only when every row is ok or excepted.
  Exceptions: ~/.config/forge-protection/exceptions (one remote URL per line).
  FORGE_PROTECTION_TIMEOUT: seconds per forge call (default 20).
EOF
}

# normalize_remote <url>: prints <host>/<path>, the form the rows and the exceptions share.
normalize_remote() {
  local u rest auth host path org
  u=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$u" in
    *://*)
      rest=${u#*://}
      auth=${rest%%/*}
      case "$rest" in */*) path=${rest#*/} ;; *) path= ;; esac
      host=${auth##*@}; host=${host%%:*}
      ;;
    *)
      case "$u" in
        *:*) host=${u%%:*}; path=${u#*:} ;;
        *) host=$u; path= ;;
      esac
      host=${host##*@}
      ;;
  esac
  while :; do
    case "$path" in
      /*) path=${path#/} ;;
      */) path=${path%/} ;;
      *.git) path=${path%.git} ;;
      *) break ;;
    esac
  done
  case "$host" in
    ssh.dev.azure.com|vs-ssh.visualstudio.com)
      path=${path#v3/}; host=dev.azure.com ;;
    dev.azure.com)
      path=$(printf '%s' "$path" | sed 's#^\([^/]*\)/\([^/]*\)/_git/#\1/\2/#') ;;
    *.visualstudio.com)
      org=${host%.visualstudio.com}
      path=${path#defaultcollection/}
      path=$(printf '%s' "$path" | sed 's#^\([^/]*\)/_git/#\1/#')
      path="$org/$path"; host=dev.azure.com ;;
  esac
  if [ "$host" = dev.azure.com ]; then
    path=$(printf '%b' "$(printf '%s' "$path" | sed 's/%\([0-9a-f][0-9a-f]\)/\\x\1/g')")
  fi
  printf '%s/%s' "$host" "$path"
}

# forge_call <tool> <args...>: sets FC_OUT, FC_ERR, FC_RC (124 on timeout, the child killed).
forge_call() {
  local o e pid n=0 max=$((LIMIT * 10))
  o="$WORK/fc.out"; e="$WORK/fc.err"
  "$@" >"$o" 2>"$e" </dev/null &
  pid=$!
  FC_RC=
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge "$max" ]; then
      pkill -P "$pid" 2>/dev/null
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      FC_RC=124
      break
    fi
    sleep 0.1
    n=$((n + 1))
  done
  if [ -z "$FC_RC" ]; then wait "$pid"; FC_RC=$?; fi
  FC_OUT=$(cat "$o"); FC_ERR=$(cat "$e")
  return "$FC_RC"
}

gh_get() {  # [--paginate] <endpoint>
  forge_call gh api "$@"
}

glab_get() {  # <endpoint>
  forge_call glab api --hostname gitlab.com "$1"
}

az_read() {  # <args...>: only read verbs
  case "$*" in
    "repos show"*|"repos policy list"*|"account show"*|"devops security permission show"*)
      forge_call az "$@" ;;
    *)
      FC_OUT=; FC_ERR="refused: az $*"; FC_RC=125; return 125 ;;
  esac
}

# fc_reason: why the last forge call failed, never more than one short line.
fc_reason() {
  local h
  if [ "$FC_RC" -eq 124 ]; then printf 'no answer within %ss' "$LIMIT"; return; fi
  h=$(printf '%s' "$FC_ERR" | grep -o 'HTTP [0-9][0-9][0-9]' | head -n 1)
  if [ -z "$h" ]; then h=$(printf '%s' "$FC_ERR" | head -n 1 | cut -c1-120); fi
  if [ -z "$h" ]; then h="exit $FC_RC"; fi
  printf '%s' "$h"
}

row() {  # <ok|drift|unreadable|excepted> <remote> [detail]
  case "$1" in
    ok) N_OK=$((N_OK + 1)) ;;
    drift) N_DRIFT=$((N_DRIFT + 1)) ;;
    unreadable) N_UNREADABLE=$((N_UNREADABLE + 1)) ;;
    excepted) N_EXCEPTED=$((N_EXCEPTED + 1)) ;;
  esac
  if [ -n "${3:-}" ]; then printf '%-10s %s  %s\n' "$1" "$2" "$3"; else printf '%-10s %s\n' "$1" "$2"; fi
}
remedy() { printf '    %s\n' "$1"; }
note() { printf '    # %s\n' "$(printf '%s' "$1" | tr -d '\000-\037\177')"; }
# shq <text>: one shell word that reads back as exactly <text> (Bash 3.2 and POSIX sh), so a
# forge-supplied branch or path pasted into a printed command cannot break out of its quotes.
shq() {
  case "$1" in
    ''|*[!A-Za-z0-9_./:@%+=,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The two rulesets of spec 2026-11-12 section 2.1, as compact JSON.
body_protect_main() {  # <ref>
  jq -nc --arg ref "$1" '{name:"protect-main",target:"branch",enforcement:"active",bypass_actors:[],conditions:{ref_name:{include:[$ref],exclude:[]}},rules:[{type:"deletion"},{type:"non_fast_forward"}]}'
}
body_main_owner_only() {
  jq -nc '{name:"main-owner-only",target:"branch",enforcement:"active",bypass_actors:[{actor_type:"RepositoryRole",actor_id:5,bypass_mode:"always"}],conditions:{ref_name:{include:["~DEFAULT_BRANCH"],exclude:[]}},rules:[{type:"update"},{type:"creation"}]}'
}

check_github() {  # <remote> <owner/repo>
  local remote=$1 repo=$2 def enc rules ids id st v n want
  case "$repo" in
    */*/*|*/|/*) row unreadable "$remote" "not an owner/repo path"; return ;;
    */*) ;;
    *) row unreadable "$remote" "not an owner/repo path"; return ;;
  esac
  if ! gh_get "repos/$repo"; then row unreadable "$remote" "$(fc_reason)"; return; fi
  def=$(printf '%s' "$FC_OUT" | jq -r '.default_branch // empty' 2>/dev/null)
  if [ -z "$def" ]; then row unreadable "$remote" "no default branch in the answer"; return; fi
  case "$def" in *[[:cntrl:]]*) row unreadable "$remote" "the default branch name holds control characters"; return ;; esac
  enc=$(jq -rn --arg b "$def" '$b | @uri')
  if ! gh_get --paginate "repos/$repo/rules/branches/$enc?per_page=100"; then
    row unreadable "$remote" "$(fc_reason)"; return
  fi
  rules=$(printf '%s' "$FC_OUT" | jq -sc 'add // []' 2>/dev/null)
  if ! printf '%s' "$rules" | jq -e 'type == "array"' >/dev/null 2>&1; then
    row unreadable "$remote" "the rules answer is not a list"; return
  fi
  ids=$(printf '%s' "$rules" | jq -r '[.[].ruleset_id | select(. != null)] | unique | .[]')
  st='{}'
  for id in $ids; do
    if ! gh_get "repos/$repo/rulesets/$id"; then row unreadable "$remote" "$(fc_reason)"; return; fi
    if ! st=$(printf '%s' "$FC_OUT" | jq -c --argjson st "$st" --arg id "$id" '
        .bypass_actors as $b | .current_user_can_bypass as $c
        | if $b == null and $c == null then error("no bypass information")
          else $st + {($id): {
            closed: (.enforcement == "active" and (($b != null and ($b | length) == 0) or ($b == null and $c == "never"))),
            owner: (.enforcement == "active" and (($b != null and ($b | length) > 0 and ($b | all(.actor_type == "RepositoryRole" and .actor_id == 5))) or ($b == null and $c == "never")))
          }} end' 2>/dev/null); then
      row unreadable "$remote" "ruleset $id shows neither bypass_actors nor current_user_can_bypass"; return
    fi
  done
  # A rule pair is "carried" by a ruleset of any enforcement; the POST for a pair is printed only
  # when no ruleset carries it, otherwise the carrier gets a UI note. A ruleset holding update or
  # creation (the rejected merged design included) is judged as the owner-only carrier and is never
  # told to empty its bypass list: protect-main is posted beside it. An empty bypass list is not
  # owner-only, since Michael could then no longer push the default branch.
  v=$(jq -nc --argjson r "$rules" --argjson st "$st" '
    def types($id): [$r[] | select(.ruleset_id == $id) | .type];
    def pair($id; $a; $b): (types($id) | (index($a) != null and index($b) != null));
    def pm($id): pair($id; "deletion"; "non_fast_forward");
    def oo($id): pair($id; "update"; "creation");
    def uc($id): (types($id) | (index("update") != null or index("creation") != null));
    def carried($t; $k): any($r[]; .type == $t and $st[(.ruleset_id | tostring)][$k]);
    ([$r[].ruleset_id | select(. != null)] | unique) as $ids
    | {ok: (carried("deletion"; "closed") and carried("non_fast_forward"; "closed") and carried("update"; "owner") and carried("creation"; "owner")),
       protect_post: ([$ids[] | select(pm(.) and (uc(.) | not))] | length == 0),
       owner_post: ([$ids[] | select(oo(.))] | length == 0),
       ui: ([$ids[] | select(pm(.) and (uc(.) | not) and ($st[tostring].closed | not)) | {id: ., want: "none"}]
          + [$ids[] | select(uc(.) and ($st[tostring].owner | not)) | {id: ., want: "Repository admin"}])}')
  if [ "$(printf '%s' "$v" | jq -r '.ok')" = true ]; then
    row ok "$remote" "default branch $def"; return
  fi
  row drift "$remote" "default branch $def"
  if [ "$(printf '%s' "$v" | jq -r '.protect_post')" = true ]; then
    remedy "gh api --method POST repos/$(shq "$repo")/rulesets --input <(printf '%s\\n' $(shq "$(body_protect_main "refs/heads/$def")"))"
  fi
  if [ "$(printf '%s' "$v" | jq -r '.owner_post')" = true ]; then
    remedy "gh api --method POST repos/$(shq "$repo")/rulesets --input <(printf '%s\\n' $(shq "$(body_main_owner_only)"))"
  fi
  n=$(printf '%s' "$v" | jq -r '.ui | length')
  while [ "$n" -gt 0 ]; do
    n=$((n - 1))
    id=$(printf '%s' "$v" | jq -r ".ui[$n].id")
    want=$(printf '%s' "$v" | jq -r ".ui[$n].want")
    note "in the UI: https://github.com/$repo/rules/$id: Enforcement Active, bypass list $want"
  done
}

check_remote() {  # <normalized remote>
  local n=$1 host path
  host=${n%%/*}; path=${n#*/}
  case "$host" in
    github.com) check_github "$n" "$path" ;;
    *) row unreadable "$n" "unknown forge host $host; an SSH host alias is read as one" ;;
  esac
}

load_exceptions() {
  local f="$HOME/.config/forge-protection/exceptions" l
  EXC=
  [ -r "$f" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    l=${l%$'\r'}
    l=${l#"${l%%[![:space:]]*}"}; l=${l%"${l##*[![:space:]]}"}
    case "$l" in ''|'#'*) continue ;; esac
    EXC="$EXC$(normalize_remote "$l")$NL"
  done < "$f"
}

cmd_check() {
  local d url n total skipped=0
  load_exceptions
  : > "$WORK/remotes"
  for d in "$HOME/.local/share/chezmoi" "$HOME"/Code/*/*; do
    [ -e "$d/.git" ] || continue
    url=$(git -C "$d" remote get-url --push origin 2>/dev/null) || url=
    if [ -z "$url" ]; then skipped=$((skipped + 1)); continue; fi
    normalize_remote "$url" >> "$WORK/remotes"; echo >> "$WORK/remotes"
  done
  sort -u "$WORK/remotes" | grep -v '^$' > "$WORK/sorted"
  total=$(wc -l < "$WORK/sorted" | tr -d ' ')
  echo "# This output names repositories: never commit it or paste it into a tracked file."
  while IFS= read -r n; do
    case "$NL$EXC" in
      *"$NL$n$NL"*) row excepted "$n" "listed in the exceptions file" ;;
      *) check_remote "$n" ;;
    esac
  done < "$WORK/sorted"
  echo "forge-protection: $total repositories: $N_OK ok, $N_DRIFT drift, $N_UNREADABLE unreadable, $N_EXCEPTED excepted; $skipped checkouts without origin skipped"
  [ $((N_DRIFT + N_UNREADABLE)) -eq 0 ]
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  check) [ $# -eq 1 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
for t in git jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "forge-protection: $t is required" >&2; exit 2; }
done
WORK=$(mktemp -d "${TMPDIR:-/tmp}/forge-protection.XXXXXX") || { echo "forge-protection: cannot create a temp dir" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
cmd_check
