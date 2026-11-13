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
AZ_DEAD=; AZ_USER=; AZ_USER_WHY=
AZ_GIT_NAMESPACE=2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87

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

glab_get() {  # [--paginate] <endpoint>
  forge_call glab api --hostname gitlab.com "$@"
}

az_read() {  # <args...>: only read verbs; the first timeout stops every later az call of the run
  local rc
  case "$*" in
    "repos show "*|"repos policy list "*|"account show "*|"devops security permission show "*)
      forge_call az "$@"; rc=$?
      if [ "$rc" -eq 124 ]; then AZ_DEAD=1; fi
      return "$rc" ;;
    *)
      FC_OUT=; FC_ERR="refused: az $*"; FC_RC=125; return 125 ;;
  esac
}

# fc_reason: why the last forge call failed, never more than one short line.
fc_reason() {
  local h
  if [ "$FC_RC" -eq 124 ]; then printf 'no answer within %ss' "$LIMIT"; return; fi
  h=$(printf '%s' "$FC_ERR" | grep -o 'HTTP [0-9][0-9][0-9]' | head -n 1)
  if [ -z "$h" ]; then h=$(printf '%s' "$FC_ERR" | head -n 1 | tr -d '\000-\037\177' | cut -c1-120); fi
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
# shq <text>: one shell word that reads back as exactly <text> in Bash 3.2, POSIX sh and zsh, so a
# forge-supplied branch or path pasted into a printed command cannot break out of its quotes. The
# unquoted-safe set holds no character that is special to any of them: `=` is out because zsh
# expands a word starting with it to a command path (and, with magic_equal_subst, name==x too), and
# `~`, `#`, `^`, `(`, `{`, `*`, `?` and `[` are out already (tilde, comment, extendedglob, glob and
# brace expansion). `%` and `,` stay: they only act at the start of a command word or inside braces.
shq() {
  case "$1" in
    ''|*[!A-Za-z0-9_./:@%+,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
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

check_gitlab() {  # <remote> <group/.../project>
  local remote=$1 path=$2 enc id def ep rules v n i name nenc json why ui
  case "$path" in
    *//*|*/|/*|'') row unreadable "$remote" "not a group/project path"; return ;;
    */*) ;;
    *) row unreadable "$remote" "not a group/project path"; return ;;
  esac
  enc=$(jq -rn --arg p "$path" '$p | @uri')
  if ! glab_get "projects/$enc"; then row unreadable "$remote" "$(fc_reason)"; return; fi
  id=$(printf '%s' "$FC_OUT" | jq -r '.id // empty | tostring' 2>/dev/null)
  def=$(printf '%s' "$FC_OUT" | jq -r '.default_branch // empty' 2>/dev/null)
  case "$id" in ''|*[!0-9]*) row unreadable "$remote" "no project id in the answer"; return ;; esac
  if [ -z "$def" ]; then row unreadable "$remote" "no default branch in the answer"; return; fi
  case "$def" in *[[:cntrl:]]*) row unreadable "$remote" "the default branch name holds control characters"; return ;; esac
  ep="projects/$id/protected_branches?per_page=100"
  if ! glab_get --paginate "$ep"; then
    row unreadable "$remote" "$(fc_reason)"; return
  fi
  rules=$(printf '%s' "$FC_OUT" | jq -sc 'add // []' 2>/dev/null)
  if ! printf '%s' "$rules" | jq -e 'type == "array"' >/dev/null 2>&1; then
    row unreadable "$remote" "the protected branches answer is not a list"; return
  fi
  # GitLab applies the most permissive matching rule, so every rule whose name is the default branch
  # or whose wildcard matches it is judged; `*` is any run of characters, anything else literal.
  if ! v=$(printf '%s' "$rules" | jq -c --arg def "$def" '
      def esc: gsub("(?<c>[^A-Za-z0-9])"; "\\\(.c)");
      def hits($n): ($n == $def) or ($def | test("\\A" + ($n | split("*") | map(esc) | join(".*")) + "\\z"; "p"));
      def pusher: (.access_level != 0) or (.user_id != null) or (.group_id != null) or (.deploy_key_id != null);
      def merger: ((.access_level == 0 or ((.access_level // 0) >= 40)) | not) or (.user_id != null) or (.group_id != null);
      def unlisted($f): (.[$f] | type) != "array";
      [.[] | select((.name | type) == "string" and hits(.name))
        | if unlisted("push_access_levels") or unlisted("merge_access_levels") then
            {name, unreadable: "rule \(.name): \(if unlisted("push_access_levels") then "push_access_levels" else "merge_access_levels" end) is not a list"}
          else
            {name, force: (.allow_force_push != false),
             push_bad: [.push_access_levels[] | select(pusher) | .id],
             push_kept: ([.push_access_levels[] | select(pusher | not)] | length),
             merge_bad: [.merge_access_levels[] | select(merger) | .id],
             merge_kept: ([.merge_access_levels[] | select(merger | not)] | length)}
            | .push_fix = ((.push_bad | length) > 0 or .push_kept == 0)
            | .merge_fix = ((.merge_bad | length) > 0 or .merge_kept == 0)
            | .body = ({}
                + (if .force then {allow_force_push: false} else {} end)
                + (if .push_fix then {allowed_to_push: ([.push_bad[] | {id: ., _destroy: true}] + (if .push_kept == 0 then [{access_level: 0}] else [] end))} else {} end)
                + (if .merge_fix then {allowed_to_merge: ([.merge_bad[] | {id: ., _destroy: true}] + (if .merge_kept == 0 then [{access_level: 40}] else [] end))} else {} end))
            | .bad = (.force or .push_fix or .merge_fix)
          end]' 2>/dev/null); then
    row unreadable "$remote" "the protected branches answer cannot be read"; return
  fi
  # A matching rule whose access-level lists are absent or not lists is never counted protected.
  why=$(printf '%s' "$v" | jq -r '[.[] | select(.unreadable) | .unreadable][0] // empty' | tr -d '\000-\037\177')
  if [ -n "$why" ]; then row unreadable "$remote" "$why"; return; fi
  n=$(printf '%s' "$v" | jq -r 'length')
  if [ "$n" -gt 0 ] && [ "$(printf '%s' "$v" | jq -r 'map(select(.bad)) | length')" -eq 0 ]; then
    row ok "$remote" "default branch $def"; return
  fi
  row drift "$remote" "default branch $def"
  if [ "$n" -eq 0 ]; then
    remedy "glab api --hostname gitlab.com --method POST $(shq "projects/$id/protected_branches") -f $(shq "name=$def") -f push_access_level=0 -f merge_access_level=40 -f allow_force_push=false"
    return
  fi
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$(printf '%s' "$v" | jq -r ".[$i].bad")" = true ]; then
      name=$(printf '%s' "$v" | jq -r ".[$i].name")
      nenc=$(jq -rn --arg p "$name" '$p | @uri')
      json=$(printf '%s' "$v" | jq -c ".[$i].body")
      remedy "glab api --hostname gitlab.com --method PATCH $(shq "projects/$id/protected_branches/$nenc") -H $(shq 'Content-Type: application/json') --input <(printf '%s\\n' $(shq "$json"))"
      note "in place, never removed and re-created"
      ui="No one"
      if [ "$(printf '%s' "$v" | jq -r ".[$i].merge_fix")" = true ]; then ui="No one (or Allowed to merge: Maintainers)"; fi
      note "or in the UI: Settings > Repository > Protected branches > $name: Allowed to push and merge: $ui; Allowed to force push: off"
    fi
    i=$((i + 1))
  done
}

# branch_token <project id> <repo id> <branch>: the Git Repositories security token of a branch,
# repoV2/<project>/<repo>/refs/heads/<each path segment as hex of its UTF-16LE bytes, joined by />/
branch_token() {
  jq -rn --arg p "$1" --arg r "$2" --arg b "$3" '
    "0123456789abcdef" as $d
    | def byte: . as $n | $d[($n / 16 | floor):($n / 16 | floor) + 1] + $d[($n % 16):($n % 16) + 1];
    def unit: if . < 65536 then [.] else (. - 65536) as $c | [55296 + ($c / 1024 | floor), 56320 + ($c % 1024)] end;
    def seg: [explode[] | unit[] | (. % 256 | byte) + (. / 256 | floor | byte)] | join("");
    "repoV2/\($p)/\($r)/refs/heads/" + ($b | split("/") | map(seg) | join("/")) + "/"'
}

# az_subject: sets AZ_USER (the signed-in user's name) from one `az account show` per run; a failed
# read is remembered in AZ_USER_WHY and not repeated. Returns 1 with the reason in AZ_USER_WHY.
az_subject() {
  if [ -n "$AZ_USER" ]; then return 0; fi
  if [ -n "$AZ_USER_WHY" ]; then return 1; fi
  if ! az_read account show --output json; then AZ_USER_WHY=$(fc_reason); return 1; fi
  AZ_USER=$(printf '%s' "$FC_OUT" | jq -r '.user.name // empty | select(type == "string")' 2>/dev/null)
  if [ -z "$AZ_USER" ]; then AZ_USER_WHY="no user name in the account answer"; return 1; fi
  return 0
}

check_azure() {  # <remote> <org> <project> <repo>
  local remote=$1 org=$2 project=$3 repo=$4 orgurl def branch rid pid pol token bits n names
  if [ -n "$AZ_DEAD" ]; then row unreadable "$remote" "az did not answer earlier in this run"; return; fi
  if [ -z "$org" ] || [ -z "$project" ] || [ -z "$repo" ]; then row unreadable "$remote" "not an org/project/repo path"; return; fi
  case "$repo" in */*) row unreadable "$remote" "not an org/project/repo path"; return ;; esac
  orgurl="https://dev.azure.com/$org"
  if ! az_read repos show --org "$orgurl" --project "$project" --repository "$repo" --output json; then
    row unreadable "$remote" "$(fc_reason)"; return
  fi
  rid=$(printf '%s' "$FC_OUT" | jq -r '.id // empty | select(type == "string")' 2>/dev/null)
  pid=$(printf '%s' "$FC_OUT" | jq -r '.project.id // empty | select(type == "string")' 2>/dev/null)
  def=$(printf '%s' "$FC_OUT" | jq -r '.defaultBranch // empty | select(type == "string")' 2>/dev/null)
  if [ -z "$rid" ]; then row unreadable "$remote" "no repository id in the answer"; return; fi
  if [ -z "$pid" ]; then row unreadable "$remote" "no project id in the answer"; return; fi
  if [ -z "$def" ]; then row unreadable "$remote" "no default branch in the answer"; return; fi
  case "$rid$pid$def" in *[[:cntrl:]]*) row unreadable "$remote" "an id or the default branch name holds control characters"; return ;; esac
  case "$def" in refs/heads/?*) branch=${def#refs/heads/} ;; *) row unreadable "$remote" "the default branch is not a branch under refs/heads"; return ;; esac
  if ! az_read repos policy list --org "$orgurl" --project "$project" --repository-id "$rid" --branch "$branch" --output json; then
    row unreadable "$remote" "$(fc_reason)"; return
  fi
  # Only a policy of type "Minimum number of reviewers" (type id fa4e907d-…, never its display name,
  # which is localised) counts. A policy without a string type id, or a reviewers policy without
  # isEnabled, isBlocking or minimumApproverCount, cannot be judged.
  if ! pol=$(printf '%s' "$FC_OUT" | jq -c '
      if type != "array" then error("not a list") else . end
      | map(if type == "object" and ((.type | type) == "object") and ((.type.id | type) == "string") then . else error("no type") end)
      | map(select(.type.id == "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd"))
      | map(if (.isEnabled | type) == "boolean" and (.isBlocking | type) == "boolean" and (.settings.minimumApproverCount | type) == "number"
            then {ok: (.isEnabled and .isBlocking and .settings.minimumApproverCount >= 1)}
            else error("fields") end)
      | {n: length, ok: any(.[]; .ok)}' 2>/dev/null); then
    row unreadable "$remote" "the policies answer is not a list of policies with their type, isEnabled, isBlocking and minimumApproverCount"; return
  fi
  if ! az_subject; then row unreadable "$remote" "$AZ_USER_WHY"; return; fi
  token=$(branch_token "$pid" "$rid" "$branch")
  if ! az_read devops security permission show --id "$AZ_GIT_NAMESPACE" --subject "$AZ_USER" --token "$token" --org "$orgurl" --output json; then
    row unreadable "$remote" "$(fc_reason)"; return
  fi
  # The answer is the documented list of access control lists, each with an acesDictionary of
  # entries carrying extendedInfo.effectiveAllow (the user's own and inherited rights). With
  # --subject the entries are the subject's, so an answer with no entry at all cannot tell nothing
  # allowed from nothing resolved: it is unreadable, as is any entry whose effectiveAllow is absent
  # or not a whole non-negative number (floor fails on anything but a number). Bits set in any
  # entry count.
  if ! bits=$(printf '%s' "$FC_OUT" | jq -c '
      if type != "array" then error("not a list") else . end
      | [.[] | if type == "object" and ((.acesDictionary | type) == "object") then .acesDictionary | .[] else error("no acesDictionary") end] as $aces
      | if ($aces | length) == 0 then error("no entry") else . end
      | [$aces[] | .extendedInfo.effectiveAllow | if . >= 0 and . == floor then . else error("effectiveAllow") end] as $e
      | [{v: 8, n: "Force push (rewrite history, delete branches and tags)"},
         {v: 128, n: "Bypass policies when pushing"},
         {v: 32768, n: "Bypass policies when completing pull requests"}]
      | map(select(. as $b | any($e[]; (. / $b.v | floor) % 2 == 1)) | .n)' 2>/dev/null); then
    row unreadable "$remote" "the permission answer holds no whole effectiveAllow for the subject"; return
  fi
  n=$(printf '%s' "$bits" | jq -r 'length')
  if [ "$(printf '%s' "$pol" | jq -r '.ok')" = true ] && [ "$n" -eq 0 ]; then
    row ok "$remote" "default branch $branch"; return
  fi
  row drift "$remote" "default branch $branch"
  if [ "$(printf '%s' "$pol" | jq -r '.n')" -eq 0 ]; then
    remedy "az repos policy approver-count create --org $(shq "$orgurl") --project $(shq "$project") --repository-id $(shq "$rid") --branch $(shq "$branch") --blocking true --enabled true --minimum-approver-count 1 --creator-vote-counts true --allow-downvotes false --reset-on-source-push false"
  elif [ "$(printf '%s' "$pol" | jq -r '.ok')" != true ]; then
    note "Repos > Branches > $branch > Branch policies: Minimum number of reviewers must be enabled, Required and ask for at least 1 reviewer"
  fi
  if [ "$n" -gt 0 ]; then
    names=$(printf '%s' "$bits" | jq -r 'map("\"" + . + "\"") | join(", ")')
    note "Repos > Branches > $branch > Branch security > $AZ_USER: set $names to Deny (if it already shows Deny for the user, a group grant is still effective: check the groups)"
  fi
}

check_remote() {  # <normalized remote>
  local n=$1 host path rest
  host=${n%%/*}; path=${n#*/}
  case "$host" in
    github.com) check_github "$n" "$path" ;;
    gitlab.com) check_gitlab "$n" "$path" ;;
    dev.azure.com)
      case "$path" in
        */*/*) rest=${path#*/}; check_azure "$n" "${path%%/*}" "${rest%%/*}" "${rest#*/}" ;;
        *) row unreadable "$n" "not an org/project/repo path" ;;
      esac ;;
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

collect() {  # <dir> <levels still to descend>: records a repository, never looks inside one
  local d=$1 left=$2 e url
  [ -d "$d" ] || return 0
  if [ -e "$d/.git" ]; then
    url=$(git -C "$d" remote get-url --push origin 2>/dev/null) || url=
    if [ -z "$url" ]; then skipped=$((skipped + 1)); return 0; fi
    normalize_remote "$url" >> "$WORK/remotes"; echo >> "$WORK/remotes"
    return 0
  fi
  [ "$left" -gt 0 ] || return 0
  for e in "$d"/*; do collect "$e" $((left - 1)); done
}

cmd_check() {
  local d n total skipped=0
  load_exceptions
  : > "$WORK/remotes"
  collect "$HOME/.local/share/chezmoi" 0
  for d in "$HOME"/Code/*; do collect "$d" 2; done
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
