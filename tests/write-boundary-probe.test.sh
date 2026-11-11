#!/usr/bin/env bash
# Tests for the chezmoi_top_git_module_hooks probe, the sibling probe and the failed_keys line of
# tests/live-write-boundary.test.sh, without measuring a sandbox.
#
# The suite runs against a throwaway HOME in TMPDIR, with a mkdir stub in front of PATH that
# refuses to create the checkout's .git/modules, or a sibling checkout under ~/.local/share, with
# a chosen message, and logs every mkdir it sees. Every other key in that run is meaningless
# (nothing is denied in a throwaway HOME), so only the keys named below and the failed_keys line
# are judged. Running it sandboxed is fine and expected; the sandbox is
# never turned off.
#
#   ./tests/write-boundary-probe.test.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="$SRC/tests/live-write-boundary.test.sh"
[ -f "$SUITE" ] || { echo "missing script under test: $SUITE" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T=$(mktemp -d "${TMPDIR:-/tmp}/wbprobe.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P) || exit 2
# W4 makes a sibling read-only; restore it so rm can remove the tree.
trap 'chmod 755 "$H/.local/share/chezmoi-wt" 2>/dev/null; rm -rf "$T"' EXIT
# git without the global and system configuration: the fixture must not sign through the agent.
g() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
H="$T/home"
cz="$H/.local/share/chezmoi"
mkdir -p "$T/bin" "$T/tmp" "$T/start" "$cz"
# The checkout, a real repository so the harness-worktree case has a common directory to compare.
g init -q -b main "$cz" \
  && g -C "$cz" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init \
  && g -C "$cz" worktree add -q "$T/wt" -b wt \
  || { echo "INCONCLUSIVE: could not build the checkout fixture" >&2; exit 2; }
cat > "$T/bin/mkdir" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${MKDIR_LOG:-/dev/null}"
for a in "$@"; do
  case "$a" in
    */.local/share/chezmoi-*) if [ -n "${STUB_SIBLING_MSG:-}" ]; then printf 'mkdir: %s: %s\n' "$a" "$STUB_SIBLING_MSG" >&2; exit 1; fi ;;
    */chezmoi/.git/modules|*/chezmoi/.git/modules/*) printf 'mkdir: %s: %s\n' "$a" "$STUB_MSG" >&2; exit 1 ;;
  esac
done
exec /bin/mkdir "$@"
STUB
chmod 755 "$T/bin/mkdir"
# With STUB_RM_KEEP_W set, rm refuses the ordinary-write file the sibling probe creates (*-w).
cat > "$T/bin/rm" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *zz-write-boundary-*-w) if [ -n "${STUB_RM_KEEP_W:-}" ]; then printf 'rm: %s: Operation not permitted\n' "$a" >&2; exit 1; fi ;;
  esac
done
exec /bin/rm "$@"
STUB
chmod 755 "$T/bin/rm"

# run_suite <stub message> <session start dir> [sibling stub message]: the suite's output, with the
# stub refusing as told; mkdir arguments go to $T/mkdir.log.
run_suite() {
  HOME="$H" TMPDIR="$T/tmp" RUN_SH_START_DIR="$2" STUB_MSG="$1" STUB_SIBLING_MSG="${3:-}" \
    MKDIR_LOG="$T/mkdir.log" PATH="$T/bin:$PATH" "$SUITE" 2>&1
}
key=chezmoi_top_git_module_hooks
# verdict <output> <expected value>
verdict() {
  local want=$2 got
  got=$(printf '%s\n' "$1" | sed -n "s/^$key=//p")
  if [ "$got" = "$want" ]; then _pass "$3"; else _fail "$3" "$key=${got:-<none>}, wanted $want"; fi
}
# listed <output> <yes|no>: whether the closing failed_keys line names the key.
listed() {
  local got=no line
  line=$(printf '%s\n' "$1" | grep -E '^failed_keys=' | tail -n 1)
  case ",${line#failed_keys=}," in *",$key,"*) got=yes ;; esac
  if [ "$got" = "$2" ]; then _pass "$3"; else _fail "$3" "$line"; fi
}

out=$(run_suite "Operation not permitted" "$T/start")
verdict "$out" DENIED "a sandbox refusal to create .git/modules reads DENIED"
listed  "$out" no     "and a DENIED probe is not listed in failed_keys"
out=$(run_suite "No such file or directory" "$T/start")
verdict "$out" ABSENT "a missing parent reads ABSENT"
listed  "$out" yes    "and an ABSENT probe is listed in failed_keys"
out=$(run_suite "Read-only file system" "$T/start")
verdict "$out" ABSENT "any other mkdir error reads ABSENT"
listed  "$out" yes    "and is listed in failed_keys"
out=$(run_suite "Operation not permitted" "$cz")
verdict "$out" SKIPPED "a session in the checkout itself still reads SKIPPED"
listed  "$out" no      "and a SKIPPED probe is not listed in failed_keys"
out=$(run_suite "Operation not permitted" "$T/wt")
verdict "$out" SKIPPED "a harness worktree of the checkout still reads SKIPPED"

# The closing line is the last thing printed, and the exit status is the failure count.
out=$(run_suite "No such file or directory" "$T/start"); rc=$?
last=$(printf '%s\n' "$out" | tail -n 1)
case "$last" in failed_keys=*) _pass "failed_keys is the last line of a failing run" ;; *) _fail "failed_keys is the last line of a failing run" "$last" ;; esac
n=$(printf '%s\n' "$last" | sed 's/^failed_keys=//' | tr ',' '\n' | grep -c .)
if [ "$rc" -eq "$n" ]; then _pass "the exit status equals the number of failed keys"; else _fail "the exit status equals the number of failed keys" "exit $rc, keys $n"; fi

# The sibling probe. value <output> <key>: the key's value, or <none>.
value() { local v; v=$(printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1); printf '%s' "${v:-<none>}"; }
# has_line <output> <ERE>: whether some line matches.
has_line() { printf '%s\n' "$1" | grep -Eq "$2"; }
shared="$H/.local/share"
sw="$shared/chezmoi-wt"

# W1: a session outside any sibling creates a scratch sibling, probes it and removes it, link included.
out=$(run_suite "Operation not permitted" "$T/start")
w=$(value "$out" sibling_write); m=$(value "$out" sibling_mcp_json)
if [ "$w" = WRITABLE ]; then _pass "W1 a scratch sibling is writable"; else _fail "W1 a scratch sibling is writable" "sibling_write=$w"; fi
case $m in "<none>"|SKIPPED) _fail "W1 the sibling battery runs" "sibling_mcp_json=$m" ;; *) _pass "W1 the sibling battery runs" ;; esac
left=$(ls -A "$shared" | grep '^chezmoi-zz-write-boundary-' || true)
if [ -z "$left" ]; then _pass "W1 the scratch sibling and its link are removed"; else _fail "W1 the scratch sibling and its link are removed" "$left"; fi

# W2: a sibling that cannot be created is inconclusive, never a pass or a failed key.
out=$(run_suite "Operation not permitted" "$T/start" "Operation not permitted"); rc=$?
w=$(value "$out" sibling_write); g=$(value "$out" sibling_git_file); m=$(value "$out" sibling_mcp_json)
if [ "$w" = DENIED ]; then _pass "W2 a refused sibling reads sibling_write=DENIED"; else _fail "W2 a refused sibling reads sibling_write=DENIED" "sibling_write=$w"; fi
if has_line "$out" '^INCONCLUSIVE: sibling:'; then _pass "W2 and prints an INCONCLUSIVE: sibling: line"; else _fail "W2 and prints an INCONCLUSIVE: sibling: line" "$out"; fi
if [ "$g" = SKIPPED ]; then _pass "W2 sibling_git_file is SKIPPED"; else _fail "W2 sibling_git_file is SKIPPED" "sibling_git_file=$g"; fi
if [ "$m" = "<none>" ]; then _pass "W2 the sibling battery does not run"; else _fail "W2 the sibling battery does not run" "sibling_mcp_json=$m"; fi
line=$(printf '%s\n' "$out" | grep -E '^failed_keys=' | tail -n 1)
case ",${line#failed_keys=}," in *,sibling_write,*) _fail "W2 sibling_write is not a failed key" "$line" ;; *) _pass "W2 sibling_write is not a failed key" ;; esac
last=$(printf '%s\n' "$out" | tail -n 1)
inc=$(printf '%s\n' "$out" | grep -n '^INCONCLUSIVE: sibling:' | head -n 1 | cut -d: -f1)
fk=$(printf '%s\n' "$out" | grep -n '^failed_keys=' | tail -n 1 | cut -d: -f1)
case "$last" in failed_keys=*) if [ -n "$inc" ] && [ -n "$fk" ] && [ "$inc" -lt "$fk" ]; then _pass "W2 failed_keys stays last, after the INCONCLUSIVE line"; else _fail "W2 failed_keys stays last, after the INCONCLUSIVE line" "inconclusive line $inc, failed_keys line $fk"; fi ;; *) _fail "W2 failed_keys stays last, after the INCONCLUSIVE line" "$last" ;; esac

# W3: a session in a sibling probes that checkout: its .git file is only opened for append, and no
# scratch sibling is made.
mkdir -p "$sw"
printf 'gitdir: /nowhere\n' > "$sw/.git"
cp "$sw/.git" "$T/git-file.before"
: > "$T/mkdir.log"
out=$(run_suite "Operation not permitted" "$sw")
w=$(value "$out" sibling_write); g=$(value "$out" sibling_git_file)
if [ "$w" = WRITABLE ]; then _pass "W3 a session sibling is writable"; else _fail "W3 a session sibling is writable" "sibling_write=$w"; fi
if [ "$g" = WRITABLE ]; then _pass "W3 sibling_git_file is measured on the session's .git file"; else _fail "W3 sibling_git_file is measured on the session's .git file" "sibling_git_file=$g, wanted WRITABLE (the file exists and nothing is denied)"; fi
if cmp -s "$sw/.git" "$T/git-file.before"; then _pass "W3 the session's .git file is unchanged"; else _fail "W3 the session's .git file is unchanged" "$(cat "$sw/.git" 2>&1)"; fi
if grep -q 'chezmoi-zz-write-boundary' "$T/mkdir.log"; then _fail "W3 no scratch sibling is made" "$(grep chezmoi-zz-write-boundary "$T/mkdir.log" | head -n 1)"; else _pass "W3 no scratch sibling is made"; fi

# W4: a session sibling that cannot be written is inconclusive too.
chmod 555 "$sw"
out=$(run_suite "Operation not permitted" "$sw")
chmod 755 "$sw"
w=$(value "$out" sibling_write); g=$(value "$out" sibling_git_file); m=$(value "$out" sibling_mcp_json)
if [ "$w" = DENIED ]; then _pass "W4 a read-only session sibling reads sibling_write=DENIED"; else _fail "W4 a read-only session sibling reads sibling_write=DENIED" "sibling_write=$w"; fi
if has_line "$out" '^INCONCLUSIVE: sibling:'; then _pass "W4 and prints an INCONCLUSIVE: sibling: line"; else _fail "W4 and prints an INCONCLUSIVE: sibling: line" "$out"; fi
if [ "$g" = SKIPPED ]; then _pass "W4 sibling_git_file is SKIPPED"; else _fail "W4 sibling_git_file is SKIPPED" "sibling_git_file=$g"; fi
if [ "$m" = "<none>" ]; then _pass "W4 the sibling battery does not run"; else _fail "W4 the sibling battery does not run" "sibling_mcp_json=$m"; fi

# W5: an ordinary-write file the sandbox lets be created but not unlinked is reported as a leftover.
out=$(STUB_RM_KEEP_W=1 run_suite "Operation not permitted" "$sw")
/bin/rm -f "$sw"/zz-write-boundary-*-w
if has_line "$out" '^cleanup=LEFT$'; then _pass "W5 a leftover ordinary-write file is reported cleanup=LEFT"; else _fail "W5 a leftover ordinary-write file is reported cleanup=LEFT" "no cleanup=LEFT line"; fi

# W6: with ~/.config present the symlink probe really writes through the link, which reads WRITABLE
# in a throwaway HOME (nothing is denied); it leaves nothing in ~/.config or ~/.local/share.
mkdir -p "$H/.config"
out=$(run_suite "Operation not permitted" "$T/start")
e=$(value "$out" sibling_symlink_escape)
if [ "$e" = WRITABLE ]; then _pass "W6 a write through the sibling-shaped link into ~/.config reads WRITABLE"; else _fail "W6 a write through the sibling-shaped link into ~/.config reads WRITABLE" "sibling_symlink_escape=$e"; fi
line=$(printf '%s\n' "$out" | grep -E '^failed_keys=' | tail -n 1)
case ",${line#failed_keys=}," in *,sibling_symlink_escape,*) _pass "W6 and the key is listed in failed_keys" ;; *) _fail "W6 and the key is listed in failed_keys" "$line" ;; esac
left=$(ls -A "$H/.config" "$shared" | grep 'zz-write-boundary-' || true)
if [ -z "$left" ]; then _pass "W6 nothing is left in ~/.config or ~/.local/share"; else _fail "W6 nothing is left in ~/.config or ~/.local/share" "$left"; fi
rmdir "$H/.config"

# W7: with the seam on and nothing else measured, a refused sibling is the only open question: the run
# exits 2 (not 0, not a failure count) and prints no failed_keys line. This is the exit-2 branch of cleanup.
out=$(WRITE_BOUNDARY_SIBLING_ONLY=1 run_suite "Operation not permitted" "$T/start" "Operation not permitted"); rc=$?
if [ "$rc" -eq 2 ]; then _pass "W7 an inconclusive-only run exits 2"; else _fail "W7 an inconclusive-only run exits 2" "exit $rc"; fi
if has_line "$out" '^INCONCLUSIVE: sibling:'; then _pass "W7 and prints an INCONCLUSIVE: sibling: line"; else _fail "W7 and prints an INCONCLUSIVE: sibling: line" "$out"; fi
if has_line "$out" '^failed_keys='; then _fail "W7 and prints no failed_keys line" "$(printf '%s\n' "$out" | grep '^failed_keys=')"; else _pass "W7 and prints no failed_keys line"; fi
if has_line "$out" '^(local_bin|config|code)='; then _fail "W7 the seam skips every non-sibling probe" "$out"; else _pass "W7 the seam skips every non-sibling probe"; fi

# W8: the seam is refused against the account's real home (from the user database, not $HOME) before
# any probe runs. Nothing is measured, so this is safe sandboxed.
real_home=$(python3 -I -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
out=$(HOME="$real_home" WRITE_BOUNDARY_SIBLING_ONLY=1 RUN_SH_START_DIR="$T/start" "$SUITE" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then _pass "W8 the seam against the real home exits 2"; else _fail "W8 the seam against the real home exits 2" "exit $rc"; fi
if has_line "$out" '^REFUSED:'; then _pass "W8 and says it was refused"; else _fail "W8 and says it was refused" "$out"; fi
if has_line "$out" '^sibling_'; then _fail "W8 and no probe ran" "$(printf '%s\n' "$out" | grep '^sibling_' | head -n 1)"; else _pass "W8 and no probe ran"; fi

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
