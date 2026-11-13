#!/usr/bin/env bash
# Canary for the CLI surface the pre-merge gate (dot_claude/xreview-guard.py) was measured on.
#
# The gate reads glab mr, gh pr and az repos pr commands. A glab, gh or az upgrade can add a command
# that proposes or lands a change (a `glab mr` verb, a `gh pr` verb, a top-level group) which the gate
# has never weighed. This suite compares the commands the installed CLIs list with the pin below,
# which holds the sorted names the gate was measured against, and the versions it was measured on.
#
#   glab mr, glab top level   `glab __complete mr ''`, `glab __complete ''`
#   gh pr, gh top level       `gh __complete pr ''`, `gh __complete ''`
#   az repos pr               the names under "Commands:" in `az repos pr --help`
#   glab api, gh api flags    the flag names of `glab __complete api -` and `gh __complete api -`
#
# Apart from the api flags it reads command names only: the gated verbs' flags are not pinned (a new
# flag on one is denied by name), but the gate reads an unknown api flag as a boolean.
# It never runs a gated verb, with or without --help.
#
# Equal to the pin: PASS per group. Different, or a CLI missing or failing: INCONCLUSIVE and exit 2,
# never exit 1, since this is the environment drifting, not a regression in this repository.
#
#   ./tests/xreview-guard-cli.test.sh   (sandboxed is fine, but only because the suite also sets
#   AZURE_EXTENSION_DIR: the azure-devops extension is read from ~/.azure/cliextensions, since a
#   fresh AZURE_CONFIG_DIR has none. Without the extension the suite reports INCONCLUSIVE.)
set -uo pipefail

PROCEDURE="read each new command's --help, then gate it, deny it or leave it, in the change that updates this pin"

PIN_VERSIONS='glab 1.130.0
gh 2.103.3
az 2.90.0, azure-devops 1.0.8'

PIN_GLAB_MR='approve
approvers
checkout
close
create
delete
diff
issues
list
merge
note
rebase
reopen
revoke
subscribe
todo
unsubscribe
update
view'

PIN_GLAB_TOP='alias
api
artifact-registry
attestation
auth
changelog
check-update
ci
cluster
config
container-registry
dependency-firewall
deploy-key
deploy-token
duo
gpg-key
incident
issue
iteration
job
label
milestone
minder
mr
opentofu
orbit
packages
release
repo
runner
runner-controller
schedule
search
securefile
security
service-account
skills
snippet
ssh-key
stack
timelog
todo
token
user
variable
version
whatsnew
work-items'

PIN_GH_PR='checkout
checks
close
comment
create
diff
edit
list
lock
merge
ready
reopen
revert
review
status
unlock
update-branch
view'

PIN_GH_TOP='agent-task
alias
api
attestation
auth
browse
cache
co
codespace
config
copilot
discussion
extension
gist
gpg-key
issue
label
licenses
org
pr
preview
project
release
repo
ruleset
run
search
secret
signoff
skill
ssh-key
status
variable
workflow'

PIN_GLAB_API_FLAGS='--field
--form
--header
--help
--hostname
--include
--input
--method
--output
--paginate
--placeholder
--raw-field
--silent
-F
-H
-X
-f
-h
-i'

PIN_GH_API_FLAGS='--allow-escape-sequences
--cache
--field
--header
--help
--hostname
--include
--input
--jq
--method
--paginate
--preview
--raw-field
--silent
--slurp
--template
--verbose
-F
-H
-X
-f
-i
-p
-q
-t'

PIN_AZ_REPOS_PR='checkout
create
list
set-vote
show
update'

WORK=$(mktemp -d "${TMPDIR:-/tmp}/xreview-guard-cli.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
# az writes a session file under its config directory, which the sandbox denies in ~/.azure. A fresh
# directory has no extensions, so the azure-devops extension is read from where it is installed.
export AZURE_CONFIG_DIR="$WORK/azure"
mkdir -p "$AZURE_CONFIG_DIR"
export AZURE_EXTENSION_DIR="${AZURE_EXTENSION_DIR:-$HOME/.azure/cliextensions}"
export AZURE_CORE_COLLECT_TELEMETRY=false

pass=0
inconclusive=0
messages=()
passes=()

note() { messages+=("INCONCLUSIVE: $1"); inconclusive=$((inconclusive + 1)); }

# cobra's own listing: the first tab-separated field of each line, without the directive line (`:4`)
# and the names help and completion.
cobra_names() { # cobra_names <cli> [<group>]
  local cli=$1; shift
  "$cli" __complete "$@" '' 2>/dev/null | awk -F'\t' '$1 != "" && $1 !~ /^:/ && $1 != "help" && $1 != "completion" { print $1 }'
}

# The flags `api` completes for `-`, as printed (--x and -x both): the gate reads an unknown api flag
# as a boolean, which is how --placeholder got past it.
api_flags() { # api_flags <cli>
  "$1" __complete api - 2>/dev/null | awk -F'\t' '$1 ~ /^-/ { print $1 }'
}

az_pr_names() {
  az repos pr --help 2>/dev/null </dev/null | awk '/^Commands:/ { on = 1; next } on && /^[[:space:]]*$/ { on = 0 } on { print $1 }'
}

# group <label> <cli> <pin> <command...>: compare the names the command prints with the pin.
group() {
  local label=$1 cli=$2 pin=$3; shift 3
  if ! command -v "$cli" >/dev/null 2>&1; then
    note "$label: $cli is not on PATH"
    return
  fi
  local got
  got=$("$@" | LC_ALL=C sort -u)
  if [ -z "$got" ]; then
    note "$label: the installed $cli listed no names (failed or unreadable)"
    return
  fi
  local want added removed
  want=$(printf '%s\n' "$pin" | LC_ALL=C sort -u)
  added=$(LC_ALL=C comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | paste -sd' ' -)
  removed=$(LC_ALL=C comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | paste -sd' ' -)
  if [ -z "$added" ] && [ -z "$removed" ]; then
    passes+=("  PASS: $label matches the pin ($(printf '%s\n' "$got" | wc -l | tr -d ' ') names)")
    pass=$((pass + 1))
  else
    note "$label: added ${added:-none}; removed ${removed:-none}"
  fi
}

group "glab mr" glab "$PIN_GLAB_MR" cobra_names glab mr
group "glab top level" glab "$PIN_GLAB_TOP" cobra_names glab
group "gh pr" gh "$PIN_GH_PR" cobra_names gh pr
group "gh top level" gh "$PIN_GH_TOP" cobra_names gh
group "az repos pr" az "$PIN_AZ_REPOS_PR" az_pr_names
group "glab api flags" glab "$PIN_GLAB_API_FLAGS" api_flags glab
group "gh api flags" gh "$PIN_GH_API_FLAGS" api_flags gh

if [ "$inconclusive" -eq 0 ]; then
  printf '%s\n' "${passes[@]}"
  exit 0
fi

# Matching groups print nothing: an INCONCLUSIVE row with PASS lines beside it reads as inconsistent.
printf '%s\n' "${messages[@]}"
az_version() {
  local core ext
  core=$(az version --query '"azure-cli"' -o tsv 2>/dev/null </dev/null | head -n 1)
  [ -n "$core" ] || return 0
  ext=$(az version --query 'extensions."azure-devops"' -o tsv 2>/dev/null </dev/null | head -n 1)
  case "$ext" in ''|None) printf 'az %s\n' "$core" ;; *) printf 'az %s, azure-devops %s\n' "$core" "$ext" ;; esac
}
installed=$({
  glab --version 2>/dev/null | head -n 1 | awk '{ print "glab " $2 }'
  gh --version 2>/dev/null | head -n 1 | awk '{ print "gh " $3 }'
  command -v az >/dev/null 2>&1 && az_version
} | paste -sd';' - | sed 's/;/; /g')
printf '  pinned on: %s\n' "$(printf '%s\n' "$PIN_VERSIONS" | paste -sd';' - | sed 's/;/; /g')"
printf '  installed: %s\n' "${installed:-no version readable}"
printf '  %s\n' "$PROCEDURE"
exit 2
