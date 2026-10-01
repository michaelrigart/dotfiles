#!/usr/bin/env bash
# Tests dot_local/bin/executable_codex, the launcher that makes every interactive Codex
# start attach to the shared daemon (spec section 5). codex-daemon is stubbed, so each
# case asserts only the launcher's own classification: which starts need the daemon,
# which are refused, and which pass straight through.
#
# Run: ./tests/run.sh codex-launcher   (sandboxed is fine)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/dot_local/bin/executable_codex"
[ -f "$L" ] || { echo "missing file under test: $L" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/codex-launcher.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/localbin" "$T/brew"
export CALLS="$T/calls" REALBIN="$T/brew/codex"
cp "$L" "$T/localbin/codex"
printf '#!/bin/sh\necho "REAL $*"\n' > "$T/brew/codex"
cat > "$T/localbin/codex-daemon" <<'D'
#!/bin/sh
echo "codex-daemon $*" >> "$CALLS"
case "$1" in
  real-bin) echo "$REALBIN" ;;
  ensure) exit "${ENSURE_RC:-0}" ;;
  check) [ "${CHECK_RC:-0}" = 0 ] || echo "codex-daemon: the daemon carries a herdr pane's environment" >&2
         exit "${CHECK_RC:-0}" ;;
esac
D
chmod +x "$T/localbin/codex" "$T/brew/codex" "$T/localbin/codex-daemon"

run() { : > "$CALLS"; PATH="$T/localbin:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$T/localbin/codex" "$@" 2>"$T/err"; }
# run_acc: like run, but never truncates $CALLS - for asserting across several invocations
# that none of them ever touched the daemon.
run_acc() { PATH="$T/localbin:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$T/localbin/codex" "$@" 2>"$T/err"; }
ensured() { grep -c 'codex-daemon ensure' "$CALLS"; }

echo "A. interactive starts attach to the daemon"
is "a bare start execs the real binary"          "$(run)" "REAL "
is "after ensuring the daemon"                   "$(ensured)" 1
is "resume is interactive"                       "$(run resume abc)" "REAL resume abc"
is "and ensures the daemon"                      "$(ensured)" 1
is "fork is interactive"                         "$(run fork)" "REAL fork"
is "a prompt argument is interactive"            "$(run 'fix the tests')" "REAL fix the tests"
is "option values are not mistaken for commands" "$(run -m exec resume x)" "REAL -m exec resume x"
is "and that start ensures the daemon"           "$(ensured)" 1
is "the pane command's own flags are allowed"    "$(run --sandbox read-only --ask-for-approval never)" "REAL --sandbox read-only --ask-for-approval never"

echo "B. a daemon that cannot start refuses the session"
out="$(ENSURE_RC=1 run)"; rc=$?
is "the start is refused"        "$rc" 1
is "and the real binary never runs" "$out" ""

echo "C. a contaminated daemon warns but does not block"
out="$(CHECK_RC=1 run)"; rc=$?
is "the session still starts"    "$out" "REAL "
is "with a warning"              "$(grep -c 'starting anyway' "$T/err")" 1

echo "D. overrides that would leave the daemon are refused"
for args in "-c model=x" "--config=model=x" "--enable foo" "--disable=foo" "resume -c k=v id"; do
  # shellcheck disable=SC2086
  out="$(run $args)"; rc=$?
  is "'$args' is refused"        "$rc" 2
  is "'$args' names --no-daemon" "$(grep -c -- '--no-daemon' "$T/err")" 1
  is "'$args' never starts"      "$out" ""
  is "'$args' never touches the daemon" "$(ensured)" 0
done

echo "E. --remote is refused for an interactive start"
out="$(run --remote ws://h:1)"; rc=$?
is "--remote <addr> is refused" "$rc" 2
is "and says herdr cannot map it" "$(grep -c 'herdr' "$T/err")" 1
is "and never touches the daemon" "$(ensured)" 0
out="$(run --remote=ws://h:1)"; rc=$?
is "--remote=<addr> is refused" "$rc" 2
is "and never touches the daemon either" "$(ensured)" 0

echo "F. explicit --no-daemon and non-interactive commands pass straight through"
: > "$CALLS"
is "--no-daemon passes through"          "$(run_acc --no-daemon)" "REAL --no-daemon"
is "--no-daemon keeps its overrides"     "$(run_acc --no-daemon -c k=v)" "REAL --no-daemon -c k=v"
is "exec passes through"                 "$(run_acc exec 'do x')" "REAL exec do x"
is "exec keeps its -c overrides"         "$(run_acc -c k=v exec foo)" "REAL -c k=v exec foo"
is "app-server passes through"           "$(run_acc app-server daemon version)" "REAL app-server daemon version"
is "--help passes through"               "$(run_acc --help)" "REAL --help"
is "--version passes through"            "$(run_acc --version)" "REAL --version"
is "e passes through"                    "$(run_acc e 'do x')" "REAL e do x"
is "review passes through"               "$(run_acc review)" "REAL review"
is "mcp passes through"                  "$(run_acc mcp)" "REAL mcp"
is "and NONE of section F ever ensured the daemon" "$(ensured)" 0

echo "G. no real binary is an error, never a loop"
printf '#!/bin/sh\nexit 1\n' > "$T/localbin/codex-daemon"; chmod +x "$T/localbin/codex-daemon"
run >/dev/null; is "the launcher exits 127" "$?" 127
is "and prints the real-codex message, not the helper's own"    "$(grep -c 'no real codex on PATH outside' "$T/err")" 1
is "the helper's own stderr is not echoed"                       "$(grep -c 'codex-daemon:' "$T/err")" 0
rm -f "$T/localbin/codex-daemon"
run >/dev/null; is "a missing helper (not just a failing one) is also 127" "$?" 127
is "and says the helper itself is missing" "$(grep -c 'codex-daemon helper is not' "$T/err")" 1
cat > "$T/localbin/codex-daemon" <<'D'
#!/bin/sh
echo "codex-daemon $*" >> "$CALLS"
case "$1" in
  real-bin) echo "$REALBIN" ;;
  ensure) exit "${ENSURE_RC:-0}" ;;
  check) [ "${CHECK_RC:-0}" = 0 ] || echo "codex-daemon: the daemon carries a herdr pane's environment" >&2
         exit "${CHECK_RC:-0}" ;;
esac
D
chmod +x "$T/localbin/codex-daemon"

echo "H. -- ends option/subcommand parsing; everything after it is a prompt"
is "'-- exec' is interactive, not the exec subcommand" "$(run -- exec)" "REAL -- exec"
is "and it ensures the daemon"                         "$(ensured)" 1
out="$(run -- '-c is wrong')"; rc=$?
is "'-- -c is wrong' is interactive, not refused"      "$rc" 0
is "and it is not treated as an override"              "$(ensured)" 1

echo "I. a help/version flag anywhere before -- passes through untouched"
is "'resume --help' passes through"        "$(run resume --help)" "REAL resume --help"
is "and never touches the daemon"          "$(ensured)" 0
out="$(run --remote ws://h:1 --help)"; rc=$?
is "'--remote ws://h:1 --help' passes through, not refused" "$out" "REAL --remote ws://h:1 --help"
is "and is not refused"                    "$rc" 0

echo "J. the helper resolves beside the launcher first, then on PATH"
mkdir -p "$T/other"
mv "$T/localbin/codex-daemon" "$T/other/codex-daemon"
out="$(PATH="$T/localbin:$T/other:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$T/localbin/codex" 2>"$T/err")"
is "PATH is the fallback when no helper sits beside the launcher" "$out" "REAL "
mv "$T/other/codex-daemon" "$T/localbin/codex-daemon"

echo "K. agents needs the daemon like an interactive start"
: > "$CALLS"
is "agents attaches to the daemon"  "$(run agents)" "REAL agents"
is "and ensures it first"           "$(ensured)" 1

echo "L. -i/--image takes several values, mirroring clap"
: > "$CALLS"
is "-i consumes every value up to the next flag" \
   "$(run -i a.png b.png --sandbox read-only foo)" "REAL -i a.png b.png --sandbox read-only foo"
# Mirroring clap's own footgun: -i swallows every bare token after it, even one that looks
# like a subcommand, up to the next flag or end of args. It is still passed through
# untouched, and the bare start still ensures the daemon regardless.
is "a bare word after -i is swallowed as an image value, not misread as a flag" \
   "$(run -i a.png resume xyz)" "REAL -i a.png resume xyz"
is "and it still ensures the daemon (an unrecognised bare start is still interactive)" \
   "$(ensured)" 1

echo "M. the daemon helper is invoked as \$HELPER, never a bare name, so PATH need not carry it"
# Invoked by absolute path with a PATH that excludes the launcher's own directory: real-bin
# resolution already uses "$HELPER", but ensure/check must too, or a bare `codex-daemon`
# hits the real (Homebrew) binary instead and fails "command not found".
: > "$CALLS"
out="$(PATH="/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$T/localbin/codex" 2>"$T/err")"; rc=$?
is "it exits 0"                                            "$rc" 0
is "and execs the real binary"                              "$out" "REAL "
is "ensure reached the helper beside the launcher"           "$(grep -c 'codex-daemon ensure' "$CALLS")" 1
is "check reached the helper beside the launcher"            "$(grep -c 'codex-daemon check' "$CALLS")" 1
is "no 'command not found' from a bare codex-daemon lookup"  "$(grep -ci 'not found' "$T/err")" 0

echo "N. a short-option CLUSTER holding h or V is also help/version, without misreading a value"
# codex -hV (0.157.1): a short cluster is not matched by the exact "-h|--help|-V|--version"
# arm, so it fell through to the launcher's ordinary interactive path and called
# ensure/check before the real binary's own -h/-V handling ever ran.
is "'-hV' (h and V clustered) passes through"       "$(run -hV)" "REAL -hV"
is "and never touches the daemon"                    "$(ensured)" 0
is "'-Vh' (order reversed) passes through"           "$(run -Vh)" "REAL -Vh"
is "and never touches the daemon"                    "$(ensured)" 0
is "'-xh' (an unrelated flag clustered with h) passes through" "$(run -xh)" "REAL -xh"
is "and never touches the daemon"                    "$(ensured)" 0
is "'resume -hV' passes through regardless of position" "$(run resume -hV)" "REAL resume -hV"
is "and never touches the daemon"                    "$(ensured)" 0
# A value-taking short flag leading the cluster makes the rest its attached value, never
# further flags - "-mV" must still ensure the daemon like any other interactive start with
# a --model value, not be misread as help/version because the value happens to contain "V".
is "'-mV' (an attached model value, not a cluster) still starts interactively" \
   "$(run -mV)" "REAL -mV"
is "because -m leads it, so it ensures the daemon like any other start" "$(ensured)" 1
# fix round 1/Minor 6: -C and -i are the OTHER value-taking short flags the exclusion covers.
# Both values below contain "h" ("home"), which must never be read as a help/version cluster.
is "'-C/home/x' (an attached cd path, not a cluster) still starts interactively" \
   "$(run -C/home/x)" "REAL -C/home/x"
is "because -C leads it, so it ensures the daemon like any other start" "$(ensured)" 1
is "'-i/home/x.png' (an attached image path, not a cluster) still starts interactively" \
   "$(run -i/home/x.png)" "REAL -i/home/x.png"
is "because -i leads it, so it ensures the daemon like any other start" "$(ensured)" 1

echo
echo "O. a resumed read-only thread stays read-only (spec 2026-10-01 §4.7)"
# run's PATH (/usr/bin) carries macOS's own jq (1.7.1), which the launcher uses.
export CODEX_HOME="$T/codexhome"
mkdir -p "$CODEX_HOME/sessions/2026/10/01"
runj() { run "$@"; }
RO=01a0f43e-af60-72c1-b15b-fb96acd74a04
RW=01a0e1d2-e958-7923-b1aa-b2257765973b
NOAP=01a0e1d3-0000-7000-8000-000000000001
NONE=01a0ffff-0000-7000-8000-000000000000
R="$CODEX_HOME/sessions/2026/10/01"
tcx() { printf '{"type":"turn_context","payload":{"sandbox_policy":{"type":"%s"},"approval_policy":"%s"}}\n' "$1" "$2"; }
{ tcx workspace-write on-request; tcx read-only never; } > "$R/rollout-2026-10-01T10-00-00-$RO.jsonl"
{ tcx read-only never; tcx workspace-write on-request; } > "$R/rollout-2026-10-01T10-00-01-$RW.jsonl"
printf '{"type":"turn_context","payload":{"sandbox_policy":{"type":"read-only"},"approval_policy":{"granular":{}}}}\n' \
  > "$R/rollout-2026-10-01T10-00-02-$NOAP.jsonl"
is "O1 a read-only thread resumes read-only with its approval policy" \
   "$(runj resume $RO)" "REAL --sandbox read-only --ask-for-approval never resume $RO"
is "O2 a non-string approval policy adds only --sandbox" \
   "$(runj resume $NOAP)" "REAL --sandbox read-only resume $NOAP"
is "O3 an explicit --sandbox wins" "$(runj --sandbox workspace-write resume $RO)" "REAL --sandbox workspace-write resume $RO"
is "O4 an explicit -s wins"        "$(runj -s workspace-write resume $RO)" "REAL -s workspace-write resume $RO"
is "O5 an explicit -a wins"        "$(runj -a on-request resume $RO)" "REAL -a on-request resume $RO"
is "O6 --ask-for-approval= wins"   "$(runj --ask-for-approval=on-request resume $RO)" "REAL --ask-for-approval=on-request resume $RO"
is "O7 --full-auto wins"           "$(runj --full-auto resume $RO)" "REAL --full-auto resume $RO"
is "O8 the bypass flag wins"       "$(runj --dangerously-bypass-approvals-and-sandbox resume $RO)" "REAL --dangerously-bypass-approvals-and-sandbox resume $RO"
is "O9 a workspace-write thread is untouched" "$(runj resume $RW)" "REAL resume $RW"
is "O10 a thread with no rollout is untouched" "$(runj resume $NONE)" "REAL resume $NONE"
is "O11 a malformed id is untouched"          "$(runj resume ../x)" "REAL resume ../x"
is "O12 resume with no id is untouched"       "$(runj resume)" "REAL resume"
is "O13 resume --last is untouched"           "$(runj resume --last)" "REAL resume --last"
is "O14 fork is untouched"                    "$(runj fork $RO)" "REAL fork $RO"
is "O15 an option value is not the subcommand" "$(runj -m resume)" "REAL -m resume"
is "O16 -C before resume still counts"        "$(runj -C /tmp resume $RO)" "REAL --sandbox read-only --ask-for-approval never -C /tmp resume $RO"
is "O17 --no-daemon resume is read-only too"  "$(runj --no-daemon resume $RO)" "REAL --sandbox read-only --ask-for-approval never --no-daemon resume $RO"
is "O18 help still passes through untouched"  "$(runj resume --help)" "REAL resume --help"
is "O19 -sVALUE attached wins"            "$(runj -sworkspace-write resume $RO)" "REAL -sworkspace-write resume $RO"
is "O20 --sandbox=VALUE wins"             "$(runj --sandbox=workspace-write resume $RO)" "REAL --sandbox=workspace-write resume $RO"
is "O21 --yolo wins"                      "$(runj --yolo resume $RO)" "REAL --yolo resume $RO"
is "O22 a mode flag after the subcommand wins" "$(runj resume -s workspace-write $RO)" "REAL resume -s workspace-write $RO"
is "O23 a -c override wins"               "$(runj --no-daemon -c sandbox_mode=workspace-write resume $RO)" "REAL --no-daemon -c sandbox_mode=workspace-write resume $RO"
is "O24 -p wins"                          "$(runj -p work resume $RO)" "REAL -p work resume $RO"
is "O25 --profile=VALUE wins"             "$(runj --profile=work resume $RO)" "REAL --profile=work resume $RO"
is "O26 -pVALUE attached wins"            "$(runj -pwork resume $RO)" "REAL -pwork resume $RO"
# A malformed line makes jq stop: the earlier read-only turn must not be mistaken for the last.
BAD=01a0e1d4-0000-7000-8000-000000000002
{ tcx read-only never; echo 'not json'; tcx workspace-write on-request; } > "$R/rollout-2026-10-01T10-00-03-$BAD.jsonl"
is "O27 a malformed rollout line is untouched" "$(runj resume $BAD)" "REAL resume $BAD"
# A last turn whose sandbox_policy is a plain string is not read-only.
STR=01a0e1d5-0000-7000-8000-000000000003
{ tcx read-only never; printf '{"type":"turn_context","payload":{"sandbox_policy":"read-only","approval_policy":"never"}}\n'; } \
  > "$R/rollout-2026-10-01T10-00-04-$STR.jsonl"
is "O28 a string sandbox_policy is untouched" "$(runj resume $STR)" "REAL resume $STR"
# An unreadable rollout.
UNR=01a0e1d6-0000-7000-8000-000000000004
tcx read-only never > "$R/rollout-2026-10-01T10-00-05-$UNR.jsonl"
chmod 000 "$R/rollout-2026-10-01T10-00-05-$UNR.jsonl"
is "O29 an unreadable rollout is untouched" "$(runj resume $UNR)" "REAL resume $UNR"
chmod 644 "$R/rollout-2026-10-01T10-00-05-$UNR.jsonl"
# No jq on PATH: only the tools the launcher itself needs, symlinked from /usr/bin.
mkdir -p "$T/nojq"
for t in find sort tail grep dirname cat; do ln -sf "/usr/bin/$t" "$T/nojq/$t"; done
is "O30 without jq the resume is untouched" \
   "$(PATH="$T/localbin:$T/nojq:/bin" XDG_BIN_HOME="$T/localbin" sh "$T/localbin/codex" resume $RO 2>"$T/err")" "REAL resume $RO"
unset CODEX_HOME

echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
