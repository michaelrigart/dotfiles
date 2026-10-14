#!/usr/bin/env bash
# Tests for dot_zshrc: Alt-k (Ghostty's Cmd-k, also forwarded by herdr/clear-pane.sh).
#
# Starts an interactive zsh on a pseudo-terminal, sources the SOURCE dot_zshrc with every
# file it sources stubbed in a temp HOME, sets a two-line prompt and presses Alt-k. Then it
# reads what zsh wrote back: the screen clear (ED2), the whole prompt redrawn after it, and
# the scrollback erase (ED3) only after the ED2, because at a prompt Ghostty answers ED2 by
# scrolling the screen into the scrollback.
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
for f in zshenv config aliases functions; do : > "$T/home/.config/zsh/$f"; done
: > "$T/omz/oh-my-zsh.sh"
: > "$T/brew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

# Prints one line: "<ed2> <ed3-after-ed2> <prompt-top-after-ed2> <prompt-bottom-after-ed2>",
# each yes/no, or a diagnostic starting with "error".
result="$("$PY" -I - "$ZSHRC" "$T" <<'PY' 2>"$T/py.err"
import os, pty, select, sys, time
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
os.write(fd, b"\x1bk")
out = read_until(None, 1.5)
os.kill(pid, 9)
os.waitpid(pid, 0)
ed2 = out.rfind(b"\x1b[2J")
yn = lambda b: "yes" if b else "no"
after = out[ed2:] if ed2 >= 0 else b""
print(yn(ed2 >= 0), yn(b"\x1b[3J" in after), yn(b"TOP-LINE" in after), yn(b"BOTTOM> " in after))
PY
)"

case "$result" in
  nopty*) echo "INCONCLUSIVE: no pseudo-terminal ($result); run it unsandboxed" >&2; exit 2 ;;
  ''|error*) _fail "the pty run completed" "${result:-$(tail -3 "$T/py.err")}" ;;
  *)
    read -r ed2 ed3 top bottom <<<"$result"
    is "Alt-k clears the screen (ED2)" "$ed2" yes
    is "the scrollback erase (ED3) follows the ED2" "$ed3" yes
    is "the prompt's top line is redrawn after the clear" "$top" yes
    is "and its bottom line" "$bottom" yes ;;
esac

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
