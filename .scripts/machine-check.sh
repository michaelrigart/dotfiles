#!/bin/zsh
# Checks this machine against .scripts/machine-checklist.tsv: one line per row that applies,
# ✓ done, ✗ not done, · no check. Every verify command is read-only; run this outside the
# sandbox, where launchctl, herdr and the firewall report truthfully.
#   machine-check.sh [--machine <name>] [--todo]
# Exit 0 every check passes, 1 one fails, 2 usage, unknown machine or malformed list.
# MACHINE_CHECK_TIMEOUT (seconds, default 30) bounds each verify command.
set -u
setopt extended_glob

DOTFILES=${0:A:h:h}
LIST="$DOTFILES/.scripts/machine-checklist.tsv"
TOML="$DOTFILES/.chezmoidata/machines.toml"

usage() { print -u2 "usage: machine-check.sh [--machine <name>] [--todo]"; exit 2; }

machine=""
todo=0
while (( $# )); do
  case "$1" in
    --machine) (( $# >= 2 )) || usage; machine=$2; shift 2 ;;
    --todo) todo=1; shift ;;
    *) usage ;;
  esac
done

t=${MACHINE_CHECK_TIMEOUT:-30}
[[ $t == <1-> ]] || { print -u2 "machine-check: MACHINE_CHECK_TIMEOUT must be a positive integer"; exit 2; }

[[ -x /usr/bin/timeout ]] || { print -u2 "machine-check: /usr/bin/timeout not found"; exit 2; }

[[ -r $TOML ]] || { print -u2 "machine-check: cannot read $TOML"; exit 2; }
known=$(sed -n 's/^known_hostnames *= *\[\(.*\)\]/\1/p' "$TOML" | tr -d '" ' | tr ',' ' ')
research=$(sed -n 's/^research_host *= *"\(.*\)"/\1/p' "$TOML")
[[ -n $known ]] || { print -u2 "machine-check: no known_hostnames in $TOML"; exit 2; }
known_list=(${=known})

[[ -n $machine ]] || machine=$(scutil --get ComputerName 2>/dev/null)
if (( ! ${known_list[(Ie)$machine]} )); then
  print -u2 "machine-check: unknown machine '$machine' (known: ${known_list[*]})"
  exit 2
fi

[[ -r $LIST ]] || { print -u2 "machine-check: cannot read $LIST"; exit 2; }

# Parse and validate the whole list before running anything.
ids=(); machs=(); steps=(); verifs=(); seen=()
n=0
bad() { print -u2 "machine-check: $LIST:$n: $1"; exit 2; }
while IFS= read -r line || [[ -n $line ]]; do
  n=$((n + 1))
  [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
  f=("${(@ps:\t:)line}")
  (( ${#f} == 5 )) || bad "expected 5 tab-separated fields, found ${#f}"
  id=$f[1]; mach=$f[2]; by=$f[3]; step=$f[4]
  verify=${${f[5]##[[:space:]]#}%%[[:space:]]#}
  [[ $id =~ '^[a-z0-9-]+$' ]] || bad "id must match [a-z0-9-]+"
  (( ${seen[(Ie)$id]} )) && bad "duplicate id $id"
  [[ $mach == all || $mach == research_host ]] || (( ${known_list[(Ie)$mach]} )) \
    || bad "machines must be all, research_host or a known machine"
  [[ $by == script || $by == you ]] || bad "by must be script or you"
  [[ -n ${step//[[:space:]]/} ]] || bad "empty step"
  [[ -n $verify ]] || bad "empty verify"
  [[ $by == script && $verify == - ]] && bad "a script row needs a verify command"
  seen+=("$id"); ids+=("$id"); machs+=("$mach"); steps+=("$step"); verifs+=("$verify")
done < "$LIST"

applies() {
  [[ $1 == all || $1 == "$machine" ]] && return 0
  [[ $1 == research_host && $machine == "$research" ]]
}

user=$(id -un)
done_n=0; todo_n=0; none_n=0
open=(); open_check=()
for (( i = 1; i <= ${#ids}; i++ )); do
  applies $machs[i] || continue
  if [[ $verifs[i] == - ]]; then
    none_n=$((none_n + 1))
    open+=("${steps[i]} [${ids[i]}] (no check)"); open_check+=("")
    (( todo )) || print -r -- "· ${ids[i]}: ${steps[i]}"
    continue
  fi
  if (cd "$HOME" && env -i MACHINE=$machine DOTFILES=$DOTFILES KNOWN_HOSTNAMES="${known_list[*]}" \
       USER=$user LOGNAME=$user HOME=$HOME XDG_CONFIG_HOME=$HOME/.config XDG_DATA_HOME=$HOME/.local/share \
       XDG_CACHE_HOME=$HOME/.cache XDG_STATE_HOME=$HOME/.local/state \
       PATH=$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
       /usr/bin/timeout -k 5 "$t" /bin/zsh -f -c "$verifs[i]" </dev/null >/dev/null 2>&1); then
    done_n=$((done_n + 1))
    (( todo )) || print -r -- "✓ ${ids[i]}"
  else
    todo_n=$((todo_n + 1))
    open+=("${steps[i]} [${ids[i]}]"); open_check+=("$verifs[i]")
    (( todo )) || print -r -- "✗ ${ids[i]}: ${steps[i]}"
  fi
done

if (( todo )); then
  if (( ${#open} )); then
    print -r -- "Still to do on $machine:"
    for (( k = 1; k <= ${#open}; k++ )); do
      print -r -- "  $k. ${open[k]}"
      [[ -n ${open_check[k]} ]] && print -r -- "     check: ${open_check[k]}"
    done
  else
    print -r -- "Nothing left to do on $machine."
  fi
else
  print "$done_n done, $todo_n to do, $none_n without a check"
fi
(( todo_n == 0 ))
