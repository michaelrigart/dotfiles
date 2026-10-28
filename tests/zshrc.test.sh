#!/usr/bin/env bash
# Tests for dot_zshrc: Cmd-k, which reaches zsh as Alt-k in a bare Ghostty tab and as
# SIGURG from herdr/clear-pane.sh inside Herdr.
#
# Starts an interactive zsh on a pseudo-terminal, sources the SOURCE dot_zshrc with every
# file it sources stubbed in a temp HOME, and sets a two-line prompt. Then, for Alt-k and for
# SIGURG at the idle prompt, it reads what zsh wrote back: the screen clear (ED2), the whole
# prompt redrawn after it, and the scrollback erase (ED3) only after the ED2, because at a
# prompt Ghostty answers ED2 by scrolling the screen into the scrollback. A SIGURG while a
# command runs must clear nothing, print no error, and not cut the command list short; the
# command stays blocked on the terminal until the test has signalled and releases it.
# Last, with the prompt drawn, the functions file changes on disk; Enter on `f` must print the
# reload line (the preexec hook) and only then the new output.
#
# Needs a pseudo-terminal, which the sandbox does not provide; there it exits 2.
#   ./tests/zshrc.test.sh
# test-requires: unsandboxed  # opens a pseudo-terminal; the sandbox has no pty devices
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ZSHRC="$SRC/dot_zshrc"
[ -f "$ZSHRC" ] || { echo "missing script under test: $ZSHRC" >&2; exit 2; }
[ -x /bin/zsh ] || { echo "no /bin/zsh" >&2; exit 2; }
PY="$(command -v python3)" || { echo "no python3" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/zshrc.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.config/zsh" "$T/omz" "$T/brew/share/zsh-syntax-highlighting"
for f in zshenv config aliases; do : > "$T/home/.config/zsh/$f"; done
printf 'f() { print OLD-F }\n' > "$T/home/.config/zsh/functions"
: > "$T/omz/oh-my-zsh.sh"
: > "$T/brew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

# Prints one line of yes/no fields, or a diagnostic starting with "error": for Alt-k, then
# for SIGURG at the prompt, "<ed2> <ed3-after-ed2> <prompt-top-after> <prompt-bottom-after>";
# then, for SIGURG while `head -n 1` holds the foreground, "<ed2> <zle error> <list ran on>";
# then, for a changed functions file and Enter on `f`, "<reload line> <before the new output>".
# Every wait is for a marker, with a timeout only as a bound.
result="$("$PY" -I - "$ZSHRC" "$T" <<'PY' 2>"$T/py.err"
import os, pty, select, signal, sys, time
zshrc, tmp = sys.argv[1], sys.argv[2]
env = {"HOME": tmp + "/home", "ZSH": tmp + "/omz", "HOMEBREW_PREFIX": tmp + "/brew",
       "TERM": "xterm-256color", "PATH": "/usr/bin:/bin"}
try:
    pid, fd = pty.fork()
except OSError as e:
    print("nopty:", e); sys.exit(0)
if pid == 0:
    os.execve("/bin/zsh", ["zsh", "-f", "-i"], env)

def read_until(marker, timeout=5.0):
    buf, end = b"", time.time() + timeout
    while time.time() < end:
        if marker is not None and marker in buf:
            return buf
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
    return buf

read_until(b"%", 3.0)
os.write(fd, ("source '%s'; PS1=$'TOP-LINE\\nBOTTOM> '\r" % zshrc).encode())
if b"BOTTOM> " not in read_until(b"BOTTOM> "):
    print("error: the two-line prompt never appeared"); sys.exit(0)
yn = lambda b: "yes" if b else "no"
def cleared(out):
    ed2 = out.rfind(b"\x1b[2J")
    after = out[ed2:] if ed2 >= 0 else b""
    return [yn(ed2 >= 0), yn(b"\x1b[3J" in after), yn(b"TOP-LINE" in after), yn(b"BOTTOM> " in after)]
fields = []
os.write(fd, b"\x1bk")
fields += cleared(read_until(b"\x1b[3J"))
os.kill(pid, signal.SIGURG)
fields += cleared(read_until(b"\x1b[3J"))
# READY-2 and AFTER-42 appear only as output, never in the echoed command line.
os.write(fd, b"print READY-$((1+1)); head -n 1 >/dev/null; print AFTER-$((40+2))\r")
if b"READY-2" not in read_until(b"READY-2"):
    print("error: the busy command never started"); sys.exit(0)
os.kill(pid, signal.SIGURG)
os.write(fd, b"release\r")
busy = read_until(b"AFTER-42")
busy += read_until(b"BOTTOM> ")
fields += [yn(b"\x1b[2J" in busy), yn(b"ZLE" in busy), yn(b"AFTER-42" in busy)]
fnp = tmp + "/home/.config/zsh/functions"
old = os.stat(fnp).st_mtime
with open(fnp, "w") as fh:
    fh.write("f() { print NEW-F }\n")
os.utime(fnp, (old + 60, old + 60))
os.write(fd, b"f\r")
reload_out = read_until(b"NEW-F")
line = b"zsh: reloaded ~/.config/zsh/functions"
fields += [yn(line in reload_out), yn(0 <= reload_out.find(line) < reload_out.find(b"NEW-F"))]
os.kill(pid, 9)
os.waitpid(pid, 0)
print(" ".join(fields))
PY
)"

case "$result" in
  nopty*) echo "INCONCLUSIVE: no pseudo-terminal ($result); run it unsandboxed" >&2; exit 2 ;;
  ''|error*) _fail "the pty run completed" "${result:-$(tail -3 "$T/py.err")}" ;;
  *)
    read -r k2 k3 ktop kbot u2 u3 utop ubot b2 berr bdone rl rlorder <<<"$result"
    is "Alt-k clears the screen (ED2)" "$k2" yes
    is "the scrollback erase (ED3) follows the ED2" "$k3" yes
    is "the prompt's top line is redrawn after the clear" "$ktop" yes
    is "and its bottom line" "$kbot" yes
    is "SIGURG at the idle prompt clears the screen (ED2)" "$u2" yes
    is "its ED3 follows the ED2" "$u3" yes
    is "its prompt's top line is redrawn after the clear" "$utop" yes
    is "and its bottom line" "$ubot" yes
    is "SIGURG while a command runs clears nothing" "$b2" no
    is "and prints no zle error" "$berr" no
    is "and the command list still runs to the end" "$bdone" yes
    is "a changed functions file prints the reload line on the next command" "$rl" yes
    is "and the reload line comes before the new function's output" "$rlorder" yes ;;
esac

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
