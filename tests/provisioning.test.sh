#!/usr/bin/env bash
# Test for the provisioning checklist .scripts/machine-checklist.tsv (spec 2026-11-22-complete-
# provisioning, section 5). Section 1: the checklist is well-formed and every verify command stays
# read-only. The lint runs against the real list and against throwaway lists, one negative fixture
# per rule, so each check is shown able to fail. The structural rules are the ones machine-check.sh
# enforces: the fixtures that break them must also make machine-check.sh exit 2, and the real list
# (every verify swapped for `true`) must pass it. No verify command of the real list ever runs here.
# Sections 2 to 5 check the repository's coverage: new specs name their provisioning, every setup
# script, LaunchAgent and Herdr plugin is reached by it; each against the real tree and a throwaway one.
# Run: ./tests/provisioning.test.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
LISTFILE="$SRC/.scripts/machine-checklist.tsv"
TOML="$SRC/.chezmoidata/machines.toml"
CHECKER="$SRC/.scripts/machine-check.sh"
pass=0; fail=0; OUT=""; RC=0
_pass(){ echo "  PASS: $1"; pass=$((pass+1)); }
_fail(){ echo "  FAIL: $1"; fail=$((fail+1)); }
rc_is(){ [ "$RC" -eq "$1" ] && _pass "$2" || _fail "$2 (rc=$RC)"; }

for f in "$LISTFILE" "$TOML" "$CHECKER"; do
  [ -f "$f" ] || { echo "MISSING SUBJECT: ${f#"$SRC"/}"; exit 2; }
done

T=$(mktemp -d "${TMPDIR:-/tmp}/provisioningtest.XXXXXX") || { echo "cannot create a temp dir"; exit 2; }
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
[ -n "$T" ] && [ -d "$T" ] || { echo "REFUSING: temp root did not resolve"; exit 2; }
mkdir -p "$T/src/.chezmoidata" "$T/src/.scripts"
cp "$TOML" "$T/src/.chezmoidata/machines.toml"
cp "$CHECKER" "$T/src/.scripts/machine-check.sh"
chmod 755 "$T/src/.scripts/machine-check.sh"

KNOWN=$(sed -n 's/^known_hostnames *= *\[\(.*\)\]/\1/p' "$TOML" | tr -d '" ' | tr ',' ' ')
[ -n "$KNOWN" ] || { echo "no known_hostnames in $TOML"; exit 2; }
FIRST_KNOWN=${KNOWN%% *}

# Left boundary of a forbidden command word: not a letter, digit, underscore, dot or dash before it.
B='(^|[^[:alnum:]_.-])'
# The verify lint's forbidden fragments: a name, the ERE that finds it, and a verify that has it.
F_NAME=(); F_RE=(); F_EX=()
forbid(){ F_NAME+=("$1"); F_RE+=("$2"); F_EX+=("$3"); }
forbid "sudo"              "${B}sudo"                              'sudo -n true'
forbid "op"                "${B}op[[:space:]]"                     'op read op://Private/Item/field'
forbid "op"                "${B}op[[:space:]]"                     'op inject -i x'
forbid "op"                "${B}op[[:space:]]"                     'op run -- true'
forbid "rm"                "${B}rm[[:space:]]"                     'rm -f /tmp/x'
forbid "mv"                "${B}mv[[:space:]]"                     'mv a b'
forbid "cp"                "${B}cp[[:space:]]"                     'cp a b'
forbid "tee"               "${B}tee[[:space:]]"                    'true | tee x'
forbid "touch"             "${B}touch[[:space:]]"                  'touch x'
forbid "mkdir"             "${B}mkdir[[:space:]]"                  'mkdir x'
forbid "ln"                "${B}ln[[:space:]]"                     'ln -s a b'
forbid "chmod"             "${B}chmod[[:space:]]"                  'chmod 600 x'
forbid "chown"             "${B}chown[[:space:]]"                  'chown me x'
forbid "kill"              "${B}(kill|killall|pkill)[[:space:]]"   'killall Dock'
forbid "kickstart"         "${B}kickstart"                         'launchctl kickstart gui/501/x'
forbid "bootstrap"         "${B}bootstrap"                         'launchctl bootstrap gui/501 x'
forbid "bootout"           "${B}bootout"                           'launchctl bootout gui/501/x'
forbid "launchctl change"  "${B}launchctl[[:space:]]+(load|unload|enable|disable|remove|submit|start|stop|kill)" 'launchctl unload x'
forbid "defaults write"    "${B}defaults[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(write|delete|import|rename)" 'defaults write com.x y 1'
forbid "osascript"         "${B}osascript"                         'osascript -e x'
forbid "open"              "${B}open[[:space:]]"                   'open -a Alfred'
forbid "netbird change"    "${B}netbird[[:space:]]+(up|down|login|logout|service)" 'netbird up'
forbid "netbird change"    "${B}netbird[[:space:]]+(up|down|login|logout|service)" 'netbird down'
forbid "herdr plugin change" "${B}herdr[[:space:]]+plugin[[:space:]]+(link|unlink|install|uninstall|enable|disable|update)" 'herdr plugin link /x'
forbid "herdr plugin change" "${B}herdr[[:space:]]+plugin[[:space:]]+(link|unlink|install|uninstall|enable|disable|update)" 'herdr plugin unlink dev.phase'
forbid "mise change"       "${B}mise[[:space:]]+(install|use|trust|upgrade|uninstall|prune|set|unset|self-update)" 'mise install'
forbid "mise change"       "${B}mise[[:space:]]+(install|use|trust|upgrade|uninstall|prune|set|unset|self-update)" 'mise use node@22'
forbid "mise change"       "${B}mise[[:space:]]+(install|use|trust|upgrade|uninstall|prune|set|unset|self-update)" 'mise trust'
forbid "daemon change"     "${B}daemon[[:space:]]+(update|start|stop|restart)" '"$real" app-server daemon update --from-cli'
forbid "launchctl change"  "${B}launchctl[[:space:]]+(setenv|unsetenv|config)" 'launchctl setenv X y'
forbid "launchctl change"  "${B}launchctl[[:space:]]+(setenv|unsetenv|config)" 'launchctl config user path /x'
forbid "sed -i"            "${B}sed[[:space:]]+(-[A-Za-z-]+[[:space:]]+)*(-[A-Za-z]*i|--in-place)" "sed -i '' s/a/b/ x"
forbid "sed -i"            "${B}sed[[:space:]]+(-[A-Za-z-]+[[:space:]]+)*(-[A-Za-z]*i|--in-place)" 'sed -n -i.bak p x'
forbid "curl output file"  "${B}curl[[:space:]]+([^|;&]*[[:space:]])?(-[A-Za-z]*[oO]|--output|--remote-name)([[:space:]]|\$)" 'curl -fsSL -o /tmp/x https://x'
forbid "curl output file"  "${B}curl[[:space:]]+([^|;&]*[[:space:]])?(-[A-Za-z]*[oO]|--output|--remote-name)([[:space:]]|\$)" 'curl --output /tmp/x https://x'
forbid "xattr change"      "${B}xattr[[:space:]]+([^|;&]*[[:space:]])?-[A-Za-z]*[wdc]" 'xattr -w a b f'
forbid "tccutil"           "${B}tccutil" 'tccutil reset All'
forbid "security change"   "${B}security[[:space:]]+(add-|delete-|import|set-|create-|remove-|unlock-keychain)" 'security add-generic-password -a x'
forbid "security change"   "${B}security[[:space:]]+(add-|delete-|import|set-|create-|remove-|unlock-keychain)" 'security delete-generic-password -a x'
forbid "brew change"       "${B}brew[[:space:]]+(install|upgrade|update|uninstall|reinstall|cleanup|tap|untap|link|unlink|services|bundle[[:space:]]+(install|cleanup|dump))" 'brew bundle install'

# lint <list>: one "line: problem" per finding on stdout; status 1 when there is one.
lint(){
  local list=$1 n=0 bad=0 line tabs id mach by step verify stripped i
  local seen=" " seen_you=0
  p(){ echo "$n: $1"; bad=1; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] && continue
    case "$line" in \#*) continue ;; esac
    tabs=$(printf '%s' "$line" | tr -cd '\t' | wc -c | tr -d ' ')
    if [ "$tabs" -ne 4 ]; then p "expected 5 tab-separated fields, found $((tabs + 1))"; continue; fi
    id=$(printf '%s\n' "$line" | cut -f1)
    mach=$(printf '%s\n' "$line" | cut -f2)
    by=$(printf '%s\n' "$line" | cut -f3)
    step=$(printf '%s\n' "$line" | cut -f4)
    verify=$(printf '%s\n' "$line" | cut -f5 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    printf '%s' "$id" | grep -Eq '^[a-z0-9-]+$' || p "id must match [a-z0-9-]+"
    case "$seen" in *" $id "*) p "duplicate id $id" ;; esac
    seen="$seen$id "
    case "$mach" in all|research_host) ;; *) case " $KNOWN " in *" $mach "*) ;; *) p "machines must be all, research_host or a known machine" ;; esac ;; esac
    case "$by" in script|you) ;; *) p "by must be script or you" ;; esac
    [ -z "$(printf '%s' "$step" | tr -d '[:space:]')" ] && p "empty step"
    [ -z "$verify" ] && p "empty verify"
    [ "$by" = script ] && [ "$verify" = - ] && p "a script row needs a verify command"
    if [ "$by" = you ]; then seen_you=1; fi
    if [ "$by" = script ] && [ "$seen_you" -eq 1 ]; then p "a script row after a you row: script rows come first"; fi
    [ -z "$verify" ] || [ "$verify" = - ] && continue
    /bin/zsh -f -n -c "$verify" >/dev/null 2>&1 || p "verify does not parse (zsh -n)"
    i=0
    while [ "$i" -lt "${#F_NAME[@]}" ]; do
      printf '%s' "$verify" | grep -Eq -- "${F_RE[$i]}" && p "verify contains ${F_NAME[$i]}"
      i=$((i + 1))
    done
    # Every sqlite3 opens its database read-only: a bare one can create or journal a file.
    if [ "$(printf '%s' "$verify" | grep -Eo "${B}sqlite3" | wc -l | tr -d ' ')" -ne \
         "$(printf '%s' "$verify" | grep -Eo "${B}sqlite3[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-readonly[[:space:]]" | wc -l | tr -d ' ')" ]; then
      p "verify runs sqlite3 without -readonly"
    fi
    # A redirect to anything but /dev/null; 2>&1 style duplications are allowed.
    stripped=$(printf '%s' "$verify" | sed -E -e 's/[0-9&]*>[[:space:]]*\/dev\/null([^[:alnum:]_\/.-]|$)/\1/g' -e 's/[0-9]*>&[0-9-]([^[:alnum:]_\/.-]|$)/\1/g')
    case "$stripped" in *">"*) p "verify redirects to a file (> or >>)" ;; esac
  done < "$list"
  return "$bad"
}

# row id machines by step verify: one tab-separated line.
row(){ printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }
fx="$T/fixture.tsv"
# lint_of <what the fixture is>: lints $fx into OUT/RC.
lint_of(){ OUT=$(lint "$fx"); RC=$?; }
says(){ case "$OUT" in *"$1"*) _pass "$2" ;; *) _fail "$2 (got: ${OUT:-nothing})" ;; esac; }
# mc <list>: machine-check.sh against the real machines.toml with this list, into OUT/RC.
mc(){ cp "$1" "$T/src/.scripts/machine-checklist.tsv"; OUT=$("$T/src/.scripts/machine-check.sh" --machine "$FIRST_KNOWN" </dev/null 2>&1); RC=$?; }
GOOD=$(row ok-row all script "Step" true)

echo "== the real checklist"
lint_of_real(){ OUT=$(lint "$LISTFILE"); RC=$?; }
lint_of_real
rc_is 0 "the real checklist passes the lint"
[ -z "$OUT" ] && _pass "the lint reports nothing for it" || _fail "the lint reports nothing for it (got: $OUT)"
[ "$(grep -vc '^#' "$LISTFILE")" -ge 40 ] && _pass "it holds its rows (not an emptied list)" || _fail "it holds its rows (not an emptied list)"
[ -x "$LISTFILE" ] && _fail "the checklist is data: not executable" || _pass "the checklist is data: not executable"
# Task 1's checker accepts it: every verify swapped for `true` (the `-` rows kept), on each known machine.
awk -F'\t' 'BEGIN { OFS = "\t" } /^#/ { print; next } NF == 5 { if ($5 !~ /^[[:space:]]*-[[:space:]]*$/) $5 = "true" } { print }' "$LISTFILE" > "$T/real-true.tsv"
for m in $KNOWN; do
  cp "$T/real-true.tsv" "$T/src/.scripts/machine-checklist.tsv"
  OUT=$("$T/src/.scripts/machine-check.sh" --machine "$m" </dev/null 2>&1); RC=$?
  rc_is 0 "machine-check.sh accepts the real list's structure on $m"
done

echo "== a clean list"
{ echo '# a comment'; echo; row ok-row all script "Step" true; row you-row "$FIRST_KNOWN" you "Do it" ' - '; row r-row research_host you "Do it" 'true >/dev/null 2>&1'; row q-row all you "Do it" 'true 2>&1 | cat >/dev/null'; } > "$fx"
lint_of; rc_is 0 "comments, blank lines, a padded '-', >/dev/null and 2>&1 pass"
mc "$fx"; rc_is 0 "and machine-check.sh accepts the same list"

echo "== structure, and agreement with machine-check.sh"
# structural <description> <expected lint text> <expected machine-check text> <the bad line>
structural(){
  { printf '%s\n' "$GOOD"; printf '%s\n' "$4"; } > "$fx"
  lint_of
  rc_is 1 "$1: the lint fails"
  says "$2" "$1: the lint names it"
  mc "$fx"
  rc_is 2 "$1: machine-check.sh exits 2 as well"
  case "$OUT" in *"$3"*) _pass "$1: with the same complaint" ;; *) _fail "$1: with the same complaint (got: $OUT)" ;; esac
}
structural "four fields" "expected 5 tab-separated fields, found 4" "expected 5 tab-separated fields" "$(printf 'x1\tall\tscript\tStep')"
structural "six fields" "expected 5 tab-separated fields, found 6" "expected 5 tab-separated fields" "$(printf 'x1\tall\tscript\tStep\ttrue\textra')"
structural "an id with a capital" "id must match [a-z0-9-]+" "id must match [a-z0-9-]+" "$(row Bad_Id all script Step true)"
structural "an empty id" "id must match [a-z0-9-]+" "id must match [a-z0-9-]+" "$(row '' all script Step true)"
structural "a duplicate id" "duplicate id ok-row" "duplicate id ok-row" "$(row ok-row all script Step true)"
structural "machines not known" "machines must be all, research_host or a known machine" "machines must be all, research_host or a known machine" "$(row x1 gamma script Step true)"
structural "by not script or you" "by must be script or you" "by must be script or you" "$(row x1 all robot Step true)"
structural "an empty step" "empty step" "empty step" "$(row x1 all script '' true)"
structural "a whitespace-only step" "empty step" "empty step" "$(row x1 all script '   ' true)"
structural "an empty verify" "empty verify" "empty verify" "$(row x1 all you Step '')"
structural "'-' on a script row" "a script row needs a verify command" "a script row needs a verify command" "$(row x1 all script Step -)"
structural "'-' with whitespace on a script row" "a script row needs a verify command" "a script row needs a verify command" "$(row x1 all script Step ' - ')"
# Only the lint has these (machine-check.sh does not enforce them).
{ row y1 all you "Manual" -; row s1 all script "Late script" true; } > "$fx"
lint_of; rc_is 1 "a script row after a you row: the lint fails"
says "2: a script row after a you row: script rows come first" "a script row after a you row: the lint names it and its line"
{ row y1 all you "Manual" -; row y2 all you "Manual too" true; } > "$fx"
lint_of; rc_is 0 "you rows after you rows are fine"
{ printf '%s\n' "$GOOD"; row p1 all script "Does not parse" 'if [ -f x ]; then'; } > "$fx"
lint_of; rc_is 1 "a verify that does not parse: the lint fails"
says "2: verify does not parse (zsh -n)" "a verify that does not parse: the lint names it and its line"
{ printf '%s\n' "$GOOD"; row p1 all script "Parses" 'if [ -f x ]; then true; fi'; } > "$fx"
lint_of; rc_is 0 "a verify that parses passes"

echo "== read-only: forbidden fragments"
i=0
while [ "$i" -lt "${#F_NAME[@]}" ]; do
  { printf '%s\n' "$GOOD"; row f1 all script "Writes" "${F_EX[$i]}"; } > "$fx"
  lint_of
  rc_is 1 "'${F_EX[$i]}': the lint fails"
  says "2: verify contains ${F_NAME[$i]}" "'${F_EX[$i]}': the lint names ${F_NAME[$i]} and its line"
  i=$((i + 1))
done
# Words that merely contain a forbidden one are not that command.
for v in 'perform=1; [ "$perform" = 1 ]' 'print -r -- "keep"' 'cmp -s a b' 'echo perform it; echo desktop stop' 'stop=1; true' 'brew bundle check --no-upgrade --file x' 'launchctl print gui/501/x' 'defaults read com.x y' 'xmllint --xpath "string(//a)" x' 'netbird status' 'herdr plugin list' 'mise ls --missing' '"$real" app-server daemon version' 'sqlite3 -readonly x.db "select 1"' 'sqlite3 -batch -readonly x.db "select 1"; sqlite3 -readonly y.db "select 2"' 'xattr -p a f' 'curl -sS --proto "=https" -w x https://x' 'sed -n "s/a/b/p" x' 'security find-generic-password -a x' 'launchctl print system/x'; do
  { printf '%s\n' "$GOOD"; row w1 all script "Fine" "$v"; } > "$fx"
  lint_of; rc_is 0 "'$v' is not flagged"
done

echo "== read-only: sqlite3 opens read-only"
for v in 'sqlite3 x.db "select 1"' 'sqlite3 -readonly x.db "select 1"; sqlite3 y.db "select 2"' 'sqlite3 -batch x.db "select 1"' 'x=$(sqlite3 -readonlyx.db 1)'; do
  { printf '%s\n' "$GOOD"; row q1 all script "Queries" "$v"; } > "$fx"
  lint_of
  rc_is 1 "'$v': the lint fails"
  says "2: verify runs sqlite3 without -readonly" "'$v': the lint names it"
done

echo "== read-only: redirects"
for v in 'true > out' 'true >out' 'true >> out' 'true 2> err' 'true &> out' 'true 1>out' 'true > /dev/nullx' 'true >/dev/null >out' 'true >&2x' 'true 2>&1x' 'true >&2file'; do
  { printf '%s\n' "$GOOD"; row r1 all script "Redirects" "$v"; } > "$fx"
  lint_of
  rc_is 1 "'$v': the lint fails"
  says "2: verify redirects to a file" "'$v': the lint names it"
done
for v in 'true >/dev/null' 'true > /dev/null' 'true 2>/dev/null' 'true &>/dev/null' 'true >/dev/null 2>&1' 'true 2>&1' 'true >&2'; do
  { printf '%s\n' "$GOOD"; row r1 all script "Redirects" "$v"; } > "$fx"
  lint_of; rc_is 0 "'$v' is allowed"
done

# ---- Sections 2 to 5: provisioning coverage. Each check is a function of a source root, run against
# the real repository and against a throwaway tree with one negative fixture.
IDS=$(grep -v '^#' "$LISTFILE" | cut -f1 | grep -v '^[[:space:]]*$')

echo "== 2: new specs declare their provisioning"
# check_specs <root>: one "<spec>: problem" per finding; status 1 when there is one. A spec dated
# 2026-11-22 or later with an after-merge style heading needs a **Provisioning:** line: `none — <reason>`
# or only backticked ids that are in the checklist (the line runs to the next blank line).
check_specs(){
  local root=$1 bad=0 f name block rest ids id
  for f in "$root"/docs/superpowers/specs/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.md; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    [[ "${name:0:10}" < "2026-11-22" ]] && continue
    grep -Eiq '^#{2,4}[[:space:]].*(michael.{1,3}s steps|after[- ]merge|rollout|migration|activation|acceptance)' "$f" || continue
    block=$(awk 'f && /^[[:space:]]*$/ { exit } /^\*\*Provisioning:\*\*/ { f = 1; sub(/^\*\*Provisioning:\*\*[[:space:]]*/, "") } f { printf "%s ", $0 }' "$f")
    if [ -z "$(printf '%s' "$block" | tr -d '[:space:]')" ]; then echo "$name: no **Provisioning:** line"; bad=1; continue; fi
    case "$block" in
      "none — "*)
        [ -n "$(printf '%s' "${block#none — }" | tr -d '[:space:]')" ] || { echo "$name: none needs a reason"; bad=1; } ;;
      *)
        ids=$(printf '%s' "$block" | grep -Eo '`[^`]*`' | tr -d '`')
        rest=$(printf '%s' "$block" | sed -E 's/`[^`]*`//g')
        if [ -z "$ids" ] || [ -n "$(printf '%s' "$rest" | tr -d '[:space:],')" ]; then
          echo "$name: **Provisioning:** is none — <reason> or backticked ids"; bad=1; continue
        fi
        for id in $ids; do
          case $'\n'"$IDS"$'\n' in *$'\n'"$id"$'\n'*) ;; *) echo "$name: $id is not in the checklist"; bad=1 ;; esac
        done ;;
    esac
  done
  return "$bad"
}
OUT=$(check_specs "$SRC"); RC=$?
rc_is 0 "the real specs declare their provisioning"
[ -z "$OUT" ] && _pass "the check reports nothing for them" || _fail "the check reports nothing for them (got: $OUT)"
[ -n "$(find "$SRC/docs/superpowers/specs" -name '2026-11-22-*.md' 2>/dev/null)" ] && _pass "a spec from the cutoff day is among them" || _fail "a spec from the cutoff day is among them"
FIRST_ID=${IDS%%$'\n'*}
spec_fx(){ # spec_fx <file name> <body>: a one-spec tree at $T/specs
  rm -rf "$T/specs"; mkdir -p "$T/specs/docs/superpowers/specs"; printf '%s\n' "$2" > "$T/specs/docs/superpowers/specs/$1"
}
spec_case(){ # spec_case <description> <name> <body> <expected rc> <expected text>
  spec_fx "$2" "$3"; OUT=$(check_specs "$T/specs"); RC=$?
  rc_is "$4" "$1"
  [ -z "$5" ] || says "$5" "$1: and names it"
}
H=$'# T\n\n## Michael\'s steps after merge\n\nDo it.'
spec_case "a new spec with steps and no line fails" 2026-11-22-x-design.md "$H" 1 "no **Provisioning:** line"
spec_case "a bare none fails" 2026-11-22-x-design.md $'# T\n**Provisioning:** none —\n\n## Rollout\nx' 1 "none needs a reason"
spec_case "none with a hyphen fails" 2026-11-22-x-design.md $'# T\n**Provisioning:** none - nothing\n\n## Rollout\nx' 1 "none — <reason> or backticked ids"
spec_case "an unknown id fails" 2026-11-22-x-design.md $'# T\n**Provisioning:** `no-such-row-xyz`\n\n## Rollout\nx' 1 "no-such-row-xyz is not in the checklist"
spec_case "ids with prose around them fail" 2026-11-22-x-design.md "$(printf '# T\n**Provisioning:** `%s` and more\n\n## Rollout\nx' "$FIRST_ID")" 1 "none — <reason> or backticked ids"
spec_case "a heading of the activation kind needs it too" 2026-12-01-x-design.md $'# T\n\n### Activation\nx' 1 "no **Provisioning:** line"
spec_case "a known id passes" 2026-11-22-x-design.md "$(printf '# T\n**Provisioning:** `%s`\n\n## Rollout\nx' "$FIRST_ID")" 0 ""
spec_case "a line that continues on the next line passes" 2026-11-22-x-design.md "$(printf '# T\n**Provisioning:** `%s`,\n`%s`\n\n## Rollout\nx' "$FIRST_ID" "$FIRST_ID")" 0 ""
spec_case "none with a reason passes" 2026-11-22-x-design.md $'# T\n**Provisioning:** none — no machine setup\n\n## Rollout\nx' 0 ""
spec_case "a spec without such a heading needs no line" 2026-11-22-x-design.md $'# T\n\n## Design\nx' 0 ""
spec_case "an older spec is exempt" 2026-11-21-x-design.md "$H" 0 ""

echo "== 3: every setup script is reachable"
ADHOC=(forge-protection.sh skill-updates.sh measure-interventions.py preflight-ssh-agent.sh)
ADHOC_WHY=("read-only forge audit, run by Michael" "weekly skill-update workflow" "workflow metrics, run by Michael" "preflight of the ssh agent, run by Michael")
# check_scripts <root>: each executable file directly in .scripts/ other than provision.sh is named
# on a non-comment line of provision.sh or configure.sh, or is in the ad-hoc table.
check_scripts(){
  local root=$1 bad=0 f name a hit
  local text; text=$(grep -hv '^[[:space:]]*#' "$root/.scripts/provision.sh" "$root/.scripts/configure.sh" 2>/dev/null)
  for f in "$root"/.scripts/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    name=$(basename "$f")
    [ "$name" = provision.sh ] && continue
    hit=0
    for a in "${ADHOC[@]}"; do [ "$a" = "$name" ] && hit=1; done
    printf '%s\n' "$text" | grep -Fq -- "$name" && hit=1
    [ "$hit" -eq 1 ] || { echo "$name is called by neither provision.sh nor configure.sh, and is not ad hoc"; bad=1; }
  done
  for a in "${ADHOC[@]}"; do [ -x "$root/.scripts/$a" ] || { echo "ad-hoc entry $a is not an executable in .scripts/"; bad=1; }; done
  return "$bad"
}
OUT=$(check_scripts "$SRC"); RC=$?
rc_is 0 "every executable in .scripts/ is reachable or ad hoc"
[ -z "$OUT" ] && _pass "the check reports nothing for the real directory" || _fail "the check reports nothing for the real directory (got: $OUT)"
[ "${#ADHOC[@]}" -eq "${#ADHOC_WHY[@]}" ] && _pass "each ad-hoc script has its reason" || _fail "each ad-hoc script has its reason"
scripts_fx(){ # a copy of the real .scripts/ top level: the two entry points, the called ones, the ad-hoc ones
  rm -rf "$T/sc"; mkdir -p "$T/sc/.scripts"
  for f in "$SRC"/.scripts/*; do [ -f "$f" ] && cp -p "$f" "$T/sc/.scripts/"; done
}
scripts_fx; OUT=$(check_scripts "$T/sc"); RC=$?
rc_is 0 "a copy of the directory passes"
printf '#!/bin/sh\n' > "$T/sc/.scripts/stray-helper.sh"; chmod 755 "$T/sc/.scripts/stray-helper.sh"
OUT=$(check_scripts "$T/sc"); RC=$?
rc_is 1 "an executable nothing calls fails"
says "stray-helper.sh is called by neither" "an executable nothing calls: the check names it"
chmod 644 "$T/sc/.scripts/stray-helper.sh"; OUT=$(check_scripts "$T/sc"); RC=$?
rc_is 0 "a data file (not executable) is not a script"
rm -f "$T/sc/.scripts/stray-helper.sh"
sed -i.bak 's/load-launchagents\.sh/loader-gone/g' "$T/sc/.scripts/configure.sh"; OUT=$(check_scripts "$T/sc"); RC=$?
rc_is 1 "a script configure.sh no longer names fails"
says "load-launchagents.sh is called by neither" "a script no longer named: the check names it"
scripts_fx; { printf '# machine-check.sh\n'; sed 's/machine-check\.sh/gone-check/g' "$SRC/.scripts/provision.sh"; } > "$T/sc/.scripts/provision.sh"
sed -i.bak 's/machine-check\.sh/gone-check/g' "$T/sc/.scripts/configure.sh"
OUT=$(check_scripts "$T/sc"); RC=$?
rc_is 1 "a name that only a comment mentions fails"
says "machine-check.sh is called by neither" "a name only in a comment: the check names it"
scripts_fx; rm -f "$T/sc/.scripts/skill-updates.sh"; OUT=$(check_scripts "$T/sc"); RC=$?
rc_is 1 "an ad-hoc entry whose script is gone fails"
says "ad-hoc entry skill-updates.sh" "an ad-hoc entry gone: the check names it"

echo "== 4: every LaunchAgent label is the loader's"
# check_labels <root>: each Library/LaunchAgents/*.plist* has a Label that starts be.netronix. and
# equals the file name without .tmpl and .plist (the loader takes the label from the file name).
check_labels(){
  local root=$1 bad=0 f name want label n=0
  for f in "$root"/Library/LaunchAgents/*.plist*; do
    [ -f "$f" ] || continue
    n=$((n + 1)); name=$(basename "$f"); want=${name%.tmpl}; want=${want%.plist}
    label=$(tr '\n' ' ' < "$f" | sed -n 's/.*<key>Label<\/key>[[:space:]]*<string>\([^<]*\)<\/string>.*/\1/p')
    case "$label" in be.netronix.*) ;; *) echo "$name: Label is not be.netronix.* (got: ${label:-none})"; bad=1; continue ;; esac
    [ "$label" = "$want" ] || { echo "$name: Label $label is not $want"; bad=1; }
  done
  [ "$n" -gt 0 ] || { echo "no LaunchAgent found"; bad=1; }
  return "$bad"
}
OUT=$(check_labels "$SRC"); RC=$?
rc_is 0 "every real LaunchAgent label is be.netronix.<file name>"
[ -z "$OUT" ] && _pass "the check reports nothing for them" || _fail "the check reports nothing for them (got: $OUT)"
plist_fx(){ # plist_fx <file name> <label>
  rm -rf "$T/la"; mkdir -p "$T/la/Library/LaunchAgents"
  printf '<plist><dict>\n    <key>Label</key>\n    <string>%s</string>\n</dict></plist>\n' "$2" > "$T/la/Library/LaunchAgents/$1"
}
plist_fx be.netronix.a.plist.tmpl be.netronix.a; OUT=$(check_labels "$T/la"); RC=$?
rc_is 0 "a .plist.tmpl whose label matches passes"
plist_fx be.netronix.a.plist be.netronix.a; OUT=$(check_labels "$T/la"); RC=$?
rc_is 0 "a plain .plist whose label matches passes"
plist_fx be.netronix.a.plist.tmpl com.example.a; OUT=$(check_labels "$T/la"); RC=$?
rc_is 1 "a label outside be.netronix. fails"
says "Label is not be.netronix.*" "a foreign label: the check names it"
plist_fx be.netronix.a.plist.tmpl be.netronix.b; OUT=$(check_labels "$T/la"); RC=$?
rc_is 1 "a label that differs from the file name fails"
says "Label be.netronix.b is not be.netronix.a" "a differing label: the check names both"
plist_fx be.netronix.a.plist.tmpl ''; OUT=$(check_labels "$T/la"); RC=$?
rc_is 1 "an empty label fails"
rm -rf "$T/la"; mkdir -p "$T/la/Library/LaunchAgents"; printf '<plist><dict></dict></plist>\n' > "$T/la/Library/LaunchAgents/be.netronix.a.plist"
OUT=$(check_labels "$T/la"); RC=$?
rc_is 1 "a plist with no label fails"
rm -rf "$T/la"; mkdir -p "$T/la/Library/LaunchAgents"; OUT=$(check_labels "$T/la"); RC=$?
rc_is 1 "an empty directory fails (not a vacuous pass)"

echo "== 5: every Herdr plugin is linked by provisioning"
# check_plugins <root>: provision.sh links the folders its non-comment `herdr/plugin-*` glob reaches;
# each dot_config/herdr/*/herdr-plugin.toml must sit in a folder that matches that glob.
check_plugins(){
  local root=$1 bad=0 f dir name n=0
  grep -v '^[[:space:]]*#' "$root/.scripts/provision.sh" | grep -Fq 'herdr/plugin-*' \
    || { echo "provision.sh has no herdr/plugin-* glob"; bad=1; }
  for f in "$root"/dot_config/herdr/*/herdr-plugin.toml; do
    [ -f "$f" ] || continue
    n=$((n + 1)); dir=$(dirname "$f"); name=$(basename "$dir")
    case "$name" in plugin-*) ;; *) echo "$name is not reached by provision.sh's plugin-* glob"; bad=1 ;; esac
  done
  [ "$n" -gt 0 ] || { echo "no Herdr plugin found"; bad=1; }
  return "$bad"
}
OUT=$(check_plugins "$SRC"); RC=$?
rc_is 0 "every real plugin sits in a folder provision.sh links"
[ -z "$OUT" ] && _pass "the check reports nothing for them" || _fail "the check reports nothing for them (got: $OUT)"
plug_fx(){ # plug_fx <folder>: a tree with provision.sh and one plugin
  rm -rf "$T/pl"; mkdir -p "$T/pl/.scripts" "$T/pl/dot_config/herdr/$1"
  cp "$SRC/.scripts/provision.sh" "$T/pl/.scripts/provision.sh"; : > "$T/pl/dot_config/herdr/$1/herdr-plugin.toml"
}
plug_fx plugin-x; OUT=$(check_plugins "$T/pl"); RC=$?
rc_is 0 "a plugin-* folder passes"
plug_fx other-x; OUT=$(check_plugins "$T/pl"); RC=$?
rc_is 1 "a plugin in a folder the glob does not reach fails"
says "other-x is not reached" "a folder outside the glob: the check names it"
plug_fx plugin-x; sed -i.bak 's#herdr/plugin-\*#herdr/gone-*#g' "$T/pl/.scripts/provision.sh"; OUT=$(check_plugins "$T/pl"); RC=$?
rc_is 1 "a provision.sh without the glob fails"
says "no herdr/plugin-* glob" "no glob: the check names it"
rm -rf "$T/pl"; mkdir -p "$T/pl/.scripts" "$T/pl/dot_config/herdr"; cp "$SRC/.scripts/provision.sh" "$T/pl/.scripts/provision.sh"
OUT=$(check_plugins "$T/pl"); RC=$?
rc_is 1 "no plugin at all fails (not a vacuous pass)"

echo
echo "Passed: $pass / $((pass + fail))"
[ "$fail" -eq 0 ]
