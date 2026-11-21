#!/usr/bin/env bash
# Tests for dot_local/bin/executable_weekly-research-proxy, the fetch proxy that is the weekly
# research job's network boundary: it must refuse the machine itself and the home network, and
# connect only to the address it checked. Literal addresses, localhost and a faked getaddrinfo
# keep every case off the network and off DNS.
#
#   ./tests/weekly-research-proxy.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
PROXY="$SRC/dot_local/bin/executable_weekly-research-proxy"
[ -f "$PROXY" ] || { echo "missing script under test: $PROXY" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/weekly-research-proxy.XXXXXX")"
PID=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

echo "A. --check: the rule, one address at a time"
# verdict <host> <port>: the first word and the exit status of --check
verdict() { local out rc; out=$("$PROXY" --check "$1" "$2" 2>&1); rc=$?; printf '%s %s' "${out%% *}" "$rc"; }
for row in "127.0.0.1 443" "10.0.0.1 443" "172.16.0.1 443" "192.168.1.1 443" \
  "169.254.169.254 80" "100.64.0.1 443" "0.0.0.0 443" "224.0.0.1 443" "::1 443" \
  "fe80::1 443" "fc00::1 443" "::ffff:127.0.0.1 443" "localhost 443" \
  "93.184.216.34 8080" "no-such-host.invalid 443"; do
  # shellcheck disable=SC2086
  is "denies $row" "$(verdict $row)" "deny 1"
done
for row in "93.184.216.34 443" "2606:2800:220:1:248:1893:25c8:1946 443"; do
  # shellcheck disable=SC2086
  is "allows $row" "$(verdict $row)" "allow 0"
done
is "prints the address it allowed" "$("$PROXY" --check 93.184.216.34 443)" "allow 93.184.216.34"

echo "B. check(): any bad address denies, the first good one is used, one lookup"
out=$(/usr/bin/python3 -I - "$PROXY" <<'EOF' 2>&1
import importlib.machinery, importlib.util, socket, sys
loader = importlib.machinery.SourceFileLoader("proxy", sys.argv[1])
spec = importlib.util.spec_from_loader("proxy", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

calls = []
def fake(addrs):
    def getaddrinfo(host, port, *a, **k):
        calls.append(host)
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, port)) for ip in addrs]
    return getaddrinfo

def run(addrs):
    del calls[:]
    socket.getaddrinfo = fake(addrs)
    return mod.check("x.example", 443), len(calls)

print("good-then-private", run(["93.184.216.34", "10.0.0.1"]))
print("private-then-good", run(["10.0.0.1", "93.184.216.34"]))
print("all-good", run(["93.184.216.34", "93.184.216.35"]))
EOF
)
case "$(printf '%s\n' "$out" | sed -n 1p)" in
  "good-then-private ((False, "*"), 1)") _pass "denies [public, private]; one getaddrinfo call" ;;
  *) _fail "denies [public, private]; one getaddrinfo call" "$out" ;;
esac
case "$(printf '%s\n' "$out" | sed -n 2p)" in
  "private-then-good ((False, "*"), 1)") _pass "denies [private, public]; one getaddrinfo call" ;;
  *) _fail "denies [private, public]; one getaddrinfo call" "$out" ;;
esac
is "allows [public, public] with the first address; one getaddrinfo call" \
  "$(printf '%s\n' "$out" | sed -n 3p)" "all-good ((True, '93.184.216.34'), 1)"

echo "C. the server refuses with 403 and logs each request"
PORTFILE="$T/port"; LOG="$T/log"
"$PROXY" --port-file "$PORTFILE" --log "$LOG" & PID=$!
for _ in $(seq 1 50); do [ -s "$PORTFILE" ] && break; sleep 0.1; done
PORT=$(cat "$PORTFILE" 2>/dev/null)
case "$PORT" in ''|*[!0-9]*) _fail "writes the port number to the port file" "${PORT:-empty}" ;;
  *) _pass "writes the port number to the port file" ;; esac
is "a CONNECT to localhost:443 answers 403" \
  "$(curl -s -o /dev/null --noproxy '' -x "http://127.0.0.1:$PORT" -w '%{http_connect}' https://localhost/ 2>/dev/null)" 403
is "one deny line for it" "$(grep -c "	deny	localhost:443	" "$LOG" 2>/dev/null)" 1
is "a plain request for http://127.0.0.1/ answers 403" \
  "$(curl -s -o /dev/null --noproxy '' -x "http://127.0.0.1:$PORT" -w '%{http_code}' http://127.0.0.1/ 2>/dev/null)" 403
is "one deny line for it" "$(grep -c "	deny	127.0.0.1:80	" "$LOG" 2>/dev/null)" 1
is "the log holds exactly those two lines" "$(wc -l < "$LOG" | tr -d ' ')" 2
case "$(sed -n 1p "$LOG")" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*"	deny	localhost:443	"?*)
    _pass "a log line is <ISO time><TAB>deny<TAB>host:port<TAB>reason" ;;
  *) _fail "a log line is <ISO time><TAB>deny<TAB>host:port<TAB>reason" "$(sed -n 1p "$LOG")" ;;
esac
kill -TERM "$PID"; wait "$PID" 2>/dev/null; rc=$?; PID=""
is "TERM ends the process with exit 0" "$rc" 0

echo "D. the relay, with the check faked to allow a local upstream"
out=$(/usr/bin/python3 -I - "$PROXY" "$T/relay.log" <<'EOF' 2>&1
import importlib.machinery, importlib.util, socket, sys, threading
loader = importlib.machinery.SourceFileLoader("proxy", sys.argv[1])
spec = importlib.util.spec_from_loader("proxy", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

# The upstream: echoes CONNECT bytes upper-cased; answers a plain request with what it saw.
up = socket.socket(); up.bind(("127.0.0.1", 0)); up.listen(5)
def serve():
    while True:
        c, _ = up.accept()
        data = c.recv(65536)
        if data.startswith((b"GET ", b"POST ")):
            body = data.split(b"\r\n\r\n")[0]
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
            c.close()
        else:
            while data:
                c.sendall(data.upper())
                data = c.recv(65536)
            c.close()
threading.Thread(target=serve, daemon=True).start()

mod.check = lambda host, port: (True, "127.0.0.1")   # host never resolves: no DNS here
srv = mod.make_server(sys.argv[2])
threading.Thread(target=srv.serve_forever, daemon=True).start()
pport, uport = srv.server_address[1], up.getsockname()[1]

s = socket.create_connection(("127.0.0.1", pport), timeout=5)
s.sendall(b"CONNECT x.example:%d HTTP/1.1\r\nHost: x.example\r\n\r\n" % uport)
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(65536)
s.sendall(b"ping")
echo = b""
while len(echo) < 4:
    echo += s.recv(65536)
print("connect", buf.split(b"\r\n")[0].decode(), echo)
s.close()

s = socket.create_connection(("127.0.0.1", pport), timeout=5)
s.sendall(b"GET http://x.example:%d/p?q=1 HTTP/1.1\r\nHost: x.example\r\nProxy-Connection: keep-alive\r\n\r\n" % uport)
buf = b""
while True:
    d = s.recv(65536)
    if not d: break
    buf += d
seen = buf.split(b"\r\n\r\n", 1)[1].decode()
print("plain", buf.split(b"\r\n")[0].decode())
print("plain-line", seen.split("\r\n")[0])
print("plain-close", "Connection: close" in seen, "Proxy-Connection" in seen)
srv.shutdown()
EOF
)
is "an allowed CONNECT answers 200 and relays bytes" "$(printf '%s\n' "$out" | sed -n 1p)" "connect HTTP/1.1 200 Connection Established b'PING'"
is "an allowed plain request is answered" "$(printf '%s\n' "$out" | sed -n 2p)" "plain HTTP/1.1 200 OK"
is "it is forwarded in origin form" "$(printf '%s\n' "$out" | sed -n 3p)" "plain-line GET /p?q=1 HTTP/1.1"
is "it carries Connection: close and no Proxy-Connection" "$(printf '%s\n' "$out" | sed -n 4p)" "plain-close True False"
is "each allowed request logs an allow line with the address" \
  "$(grep -c "	allow	x.example:[0-9]*	127.0.0.1$" "$T/relay.log" 2>/dev/null)" 2

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
