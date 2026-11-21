#!/usr/bin/env bash
# test-requires: unsandboxed, model  # sandbox-exec cannot start inside the sandbox; spends two haiku calls
# Canary that the weekly research job's boundary holds on this machine, with the real
# sandbox-exec, the real curl, python and claude. The default suites stub those; this one does not.
# The checkout's wrapper and proxy are staged together in a scratch bin/, its network.sb and a
# short prompt and source list in a scratch config folder, so nothing deployed is read and
# nothing outside the scratch directory (and $TMPDIR) is written.
#
# Profile rows (no model), each "must fail" destination first run WITHOUT the profile, so a
# refusal under the profile is shown to come from the profile. A control that already fails the
# same way (a refusal at once) makes the row INCONCLUSIVE, never ok:
#   1.1.1.1, a LAN address, another loopback listener, and a throwaway Unix socket fail under
#   the profile; the staged proxy is reachable under it, and its log says allow.
# The lock's staleness check: the wrapper's own `ps -o lstart=` and BSD `date -j` parse, run
# against a real live process, lands within a few seconds of `date +%s` (the default suite stubs
# ps, so a future macOS format change fails only here).
# Wrapper rows (the model): one run of the staged wrapper over a two-row list, haiku, budget
# 0.5, the real HOME for the login. It is retried once only when its body or Seen table was
# refused (haiku sometimes strays from the shape), so at most two model runs. Expected:
# last-run says result=ok, the note exists, the proxy log has an allow for example.com:443 and a
# deny for localtest.me, the init event of the saved stream is the restricted one, and nothing
# was written outside the scratch state and inbox. The CLI also makes connections the proxy
# denies (telemetry), so the rows assert on the lines they expect, never on the log holding only
# them.
#
# Exit 1 on a FAIL, else 2 on an INCONCLUSIVE, else 0. Run after each Claude Code upgrade:
#
#   ./tests/live-weekly-research.test.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER=dot_local/bin/executable_weekly-research
PROXY=dot_local/bin/executable_weekly-research-proxy
PROFILE=dot_config/weekly-research/network.sb

for f in "$WRAPPER" "$PROXY" "$PROFILE"; do
  [ -f "$SRC/$f" ] || { echo "INCONCLUSIVE: $f is missing, so there is no job boundary to test"; exit 2; }
done
for t in claude jq curl sandbox-exec; do
  command -v "$t" >/dev/null 2>&1 || { echo "INCONCLUSIVE: $t is not on PATH"; exit 2; }
done
[ -x /usr/bin/python3 ] || { echo "INCONCLUSIVE: /usr/bin/python3 is missing"; exit 2; }
[ -n "${HOME:-}" ] || { echo "INCONCLUSIVE: HOME is not set"; exit 2; }
if ! sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then
  echo "INCONCLUSIVE: sandbox-exec cannot start (this suite is running sandboxed); run it with the sandbox disabled"
  exit 2
fi

S=$(mktemp -d "${TMPDIR:-/tmp}/lwr.XXXXXX") || { echo "INCONCLUSIVE: no scratch directory"; exit 2; }
case $S in
  */lwr.??????) ;;
  *) echo "INCONCLUSIVE: unexpected scratch directory $S"; exit 2 ;;
esac
pids=""
cleanup() {
  local p
  for p in $pids; do kill "$p" 2>/dev/null; done
  for p in $pids; do wait "$p" 2>/dev/null; done
  rm -rf -- "$S"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

nfail=0; ninc=0
ok() { echo "  ok  $1"; }
bad() { printf '  FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '    | %s\n' "$2"; nfail=$((nfail + 1)); }
inconclusive() { echo "INCONCLUSIVE: $1"; ninc=$((ninc + 1)); }
note() { printf '  info %s\n' "$1"; }

mkdir "$S/bin" "$S/config" "$S/helpers" "$S/probe" "$S/state" "$S/inbox" || exit 2
BIN=$S/bin; CFG=$S/config
cp "$SRC/$WRAPPER" "$BIN/weekly-research" && cp "$SRC/$PROXY" "$BIN/weekly-research-proxy" \
  && cp "$SRC/$PROFILE" "$CFG/network.sb" || { echo "INCONCLUSIVE: cannot stage the job files"; exit 2; }
chmod 755 "$BIN/weekly-research" "$BIN/weekly-research-proxy"

cat >"$S/helpers/listener.py" <<'PY'
import http.server, os, socket, sys
kind, target = sys.argv[1], sys.argv[2]
if kind == "tcp":
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", "6")
            self.end_headers()
            self.wfile.write(b"hello\n")
        def log_message(self, *args):
            pass
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    with open(target + ".tmp", "w") as h:
        h.write("%d\n" % srv.server_address[1])
    os.replace(target + ".tmp", target)
    srv.serve_forever()
else:
    srv = socket.socket(socket.AF_UNIX)
    srv.bind(target)
    srv.listen(5)
    open(target + ".ready", "w").write("1")
    while True:
        conn, _ = srv.accept()
        conn.sendall(b"hello\n")
        conn.close()
PY
cat >"$S/helpers/unix_client.py" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(5)
s.connect(sys.argv[1])
print(s.recv(16))
PY

# wait_for <file>: up to 5 s for a non-empty file.
wait_for() { local i=0; while [ "$i" -lt 50 ]; do [ -s "$1" ] && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }

# --- what the profile rows need: the staged proxy, another loopback listener, a Unix socket ---
"$BIN/weekly-research-proxy" --port-file "$S/probe/proxy.port" --log "$S/probe/proxy.log" >/dev/null 2>"$S/probe/proxy.err" &
pids="$pids $!"
/usr/bin/python3 -I "$S/helpers/listener.py" tcp "$S/probe/other.port" >/dev/null 2>&1 &
pids="$pids $!"
SOCK=$S/probe/u.sock
/usr/bin/python3 -I "$S/helpers/listener.py" unix "$SOCK" >/dev/null 2>&1 &
pids="$pids $!"
wait_for "$S/probe/proxy.port" || { echo "INCONCLUSIVE: the staged proxy did not start: $(head -n 1 "$S/probe/proxy.err" | cut -c1-160)"; exit 2; }
wait_for "$S/probe/other.port" || { echo "INCONCLUSIVE: the throwaway loopback listener did not start"; exit 2; }
wait_for "$SOCK.ready" || { echo "INCONCLUSIVE: the throwaway Unix socket did not start"; exit 2; }
PPORT=$(cat "$S/probe/proxy.port"); OPORT=$(cat "$S/probe/other.port")

# probe <none|profile> <curl args...>: sets p_rc, p_ms (curl's total time) and p_out (http code).
probe() {
  local mode=$1 o
  shift
  if [ "$mode" = profile ]; then
    o=$(/usr/bin/sandbox-exec -D "PROXY_PORT=$PPORT" -f "$CFG/network.sb" \
      /usr/bin/curl -sS -m 5 -o /dev/null -w '%{http_code} %{time_total}' "$@" 2>/dev/null)
  else
    o=$(/usr/bin/curl -sS -m 5 -o /dev/null -w '%{http_code} %{time_total}' "$@" 2>/dev/null)
  fi
  p_rc=$?
  p_out=${o%% *}
  p_ms=$(printf '%s' "${o#* }" | awk '{ printf "%d", $1 * 1000 }')
}
# refused_at_once: curl exit 7 (could not connect) in under two seconds.
refused_at_once() { [ "$p_rc" -eq 7 ] && [ "${p_ms:-9999}" -lt 2000 ]; }

# must_fail <name> <url> [need_reachable]: the profile refuses at once what the control reaches or
# at least does not refuse at once. With need_reachable the control must answer 200.
must_fail() {
  local name=$1 url=$2 reach=${3:-} c_rc c_out c_ms
  probe none --noproxy '*' "$url"
  c_rc=$p_rc; c_out=$p_out; c_ms=$p_ms
  probe profile --noproxy '*' "$url"
  if refused_at_once_of "$c_rc" "$c_ms"; then
    inconclusive "$name: the control without the profile is refused at once too (curl exit $c_rc after $c_ms ms), so the profile is not shown to cause it"
  elif [ -n "$reach" ] && [ "$c_out" != 200 ]; then
    inconclusive "$name: the control without the profile did not answer 200 (curl exit $c_rc, http $c_out)"
  elif refused_at_once; then
    ok "$name: refused at once under the profile (control without it: curl exit $c_rc, http $c_out, $c_ms ms)"
  else
    bad "$name: not refused at once under the profile" "curl exit $p_rc, http $p_out, $p_ms ms (control: exit $c_rc, http $c_out)"
  fi
}
refused_at_once_of() { [ "$1" -eq 7 ] && [ "${2:-9999}" -lt 2000 ]; }

must_fail "1.1.1.1 over https" https://1.1.1.1
must_fail "a LAN address (192.168.1.1)" http://192.168.1.1
must_fail "another loopback listener" "http://127.0.0.1:$OPORT/" reach

# a Unix socket: reachable without the profile, a PermissionError under it
c=$(/usr/bin/python3 -I "$S/helpers/unix_client.py" "$SOCK" 2>&1); c_rc=$?
u=$(/usr/bin/sandbox-exec -D "PROXY_PORT=$PPORT" -f "$CFG/network.sb" /usr/bin/python3 -I "$S/helpers/unix_client.py" "$SOCK" 2>&1); u_rc=$?
if [ "$c_rc" -ne 0 ] || ! printf '%s' "$c" | grep -q hello; then
  inconclusive "a Unix socket: the control without the profile did not connect (exit $c_rc)"
elif [ "$u_rc" -ne 0 ] && printf '%s' "$u" | grep -q PermissionError && ! printf '%s' "$u" | grep -q hello; then
  ok "a Unix socket: refused with a PermissionError under the profile (control without it connected)"
else
  bad "a Unix socket: not refused under the profile" "exit $u_rc: $(printf '%s' "$u" | tail -n 1 | cut -c1-160)"
fi

# the proxy is the one way out
body=$(/usr/bin/sandbox-exec -D "PROXY_PORT=$PPORT" -f "$CFG/network.sb" \
  /usr/bin/curl -sS -m 20 -x "http://127.0.0.1:$PPORT" https://example.com 2>"$S/probe/curl.err"); b_rc=$?
if [ "$b_rc" -eq 0 ] && printf '%s' "$body" | grep -q 'Example Domain'; then
  ok "the staged proxy fetches https://example.com under the profile"
else
  bad "the staged proxy fetch of https://example.com under the profile" "curl exit $b_rc: $(head -n 1 "$S/probe/curl.err" | cut -c1-160)"
fi
if awk -F'\t' '$2 == "allow" && $3 == "example.com:443" { f = 1 } END { exit !f }' "$S/probe/proxy.log"; then
  ok "the proxy log has an allow for example.com:443"
else
  bad "the proxy log has an allow for example.com:443" "$(tail -n 3 "$S/probe/proxy.log" | cut -c1-160 | tr '\n' ' ')"
fi

# --- the lock's staleness parse, against a real live process ---
before=$(date +%s)
sleep 60 &
spid=$!
pids="$pids $spid"
after=$(date +%s)
started=$(LC_ALL=C ps -o lstart= -p "$spid" 2>/dev/null)
epoch=$(LC_ALL=C /bin/date -j -f '%a %b %e %T %Y' "$started" +%s 2>/dev/null)
started=$(printf '%s' "$started" | tr -s ' ')
if [[ $epoch =~ ^[0-9]+$ ]] && [ "$epoch" -ge $((before - 2)) ] && [ "$epoch" -le $((after + 2)) ]; then
  ok "ps -o lstart= and date -j read a live process's start within 2 s of date +%s ($started)"
else
  bad "ps -o lstart= and date -j read a live process's start time" "lstart='$started' parsed to '${epoch:-}', expected $before..$after"
fi

# --- the wrapper, with the model ---
printf 'example\tofficial\thttps://example.com\nlocaltest\tindependent\thttps://localtest.me/\n' >"$CFG/sources.tsv"
cat >"$CFG/prompt.md" <<'PROMPT'
# Live check

You run unattended with two tools: WebFetch and WebSearch. For each row under "Sources", fetch its
url once with WebFetch. Do not search, do not follow links and do not retry a fetch that fails.

Your final message is the body of a note and nothing else: no preamble, no front matter, no code
fence. Keep these five level-two headings exactly as written, once each, in this order, and write
no other level-two heading:

```
## Proposals
None this week.

## Evidence on settled questions
None.

## New this week, no change proposed
None.

## Pages that addressed the agent
None.

## Seen
| id | newest item date | newest item title, or fetch failed |
|---|---|---|
| <id> | <YYYY-MM-DD, or - when the page shows no date> | <title, or fetch failed> |
```

"Seen" has one row for every id under "Sources", in that order: the page's title, and `-` as its
date when the page shows none. Use `fetch failed` as the title of a url you could not fetch.
PROMPT
today=$(date +%Y-%m-%d)
CLAUDE_DIR=$(dirname "$(command -v claude)")
real_snap() {
  find "$HOME/.config/weekly-research" "$HOME/.local/state/weekly-research" -type f \
    -exec stat -f '%N %m %z' {} + 2>/dev/null | sort
}
tree_sum() { (find "$BIN" "$CFG" -type f -exec cksum {} + 2>/dev/null | sed "s#$S##" | sort); }
real_before=$(real_snap)
tree_before=$(tree_sum)

run_wrapper() { # run_wrapper <n>: fresh state and inbox, one run of the staged wrapper
  rm -rf -- "$S/state" "$S/inbox"
  mkdir "$S/state" "$S/inbox" || return 1
  WEEKLY_RESEARCH_CONFIG=$CFG WEEKLY_RESEARCH_STATE=$S/state WEEKLY_RESEARCH_INBOX=$S/inbox \
    WEEKLY_RESEARCH_TODAY=$today WEEKLY_RESEARCH_MODEL=haiku WEEKLY_RESEARCH_BUDGET=0.5 \
    WEEKLY_RESEARCH_TIMEOUT=600 \
    WEEKLY_RESEARCH_PATH="$CLAUDE_DIR:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$BIN/weekly-research" </dev/null >"$S/probe/wrapper.out.$1" 2>"$S/probe/wrapper.err.$1"
  w_rc=$?
}
last() { sed -n "s/^$1=//p" "$S/state/last-run" 2>/dev/null | head -n 1; }

attempt=1
run_wrapper 1
if [ "$w_rc" -ne 0 ] && last reason | grep -qE 'body|Seen|headings|rows were fetched'; then
  note "the first run failed on its answer's shape ($(last reason | cut -c1-120)); running once more"
  attempt=2
  run_wrapper 2
fi
LOGS=$S/state/logs
note "the wrapper exited $w_rc on attempt $attempt: $(head -n 1 "$S/probe/wrapper.out.$attempt" | cut -c1-160)"

if [ "$w_rc" -eq 0 ] && [ "$(last result)" = ok ]; then
  ok "the wrapper's last-run says result=ok"
else
  bad "the wrapper's last-run says result=ok" "exit $w_rc, result=$(last result), reason=$(last reason | cut -c1-200), stderr: $(head -n 1 "$S/probe/wrapper.err.$attempt" | cut -c1-200)"
fi

NOTE=$S/state/notes/$today.md
if [ -s "$NOTE" ] && grep -q '^run: ok$' "$NOTE" && grep -q '^model: haiku$' "$NOTE" \
  && grep -qE '^rows_fetched: [0-9]+ of 2$' "$NOTE"; then
  ok "the note exists with run: ok, model: haiku and rows_fetched of 2 ($(grep '^rows_fetched:' "$NOTE"))"
else
  bad "the note exists with run: ok, model: haiku and rows_fetched of 2" "$(head -n 12 "$NOTE" 2>/dev/null | cut -c1-120 | tr '\n' '|')"
fi

PLOG=$LOGS/$today.proxy.log
if awk -F'\t' '$2 == "allow" && $3 == "example.com:443" { f = 1 } END { exit !f }' "$PLOG" 2>/dev/null; then
  ok "the run's proxy log has an allow for example.com:443"
else
  bad "the run's proxy log has an allow for example.com:443" "$(cut -f2,3 "$PLOG" 2>/dev/null | sort -u | tr '\t\n' ': ' | cut -c1-300)"
fi
if awk -F'\t' '$2 == "deny" && $3 ~ /^localtest\.me:(80|443)$/ { f = 1 } END { exit !f }' "$PLOG" 2>/dev/null; then
  ok "the run's proxy log has a deny for localtest.me"
else
  bad "the run's proxy log has a deny for localtest.me" "$(cut -f2,3 "$PLOG" 2>/dev/null | sort -u | tr '\t\n' ': ' | cut -c1-300)"
fi
if awk -F'\t' '$2 == "allow" && $3 == "api.anthropic.com:443" { f = 1 } END { exit !f }' "$PLOG" 2>/dev/null; then
  ok "the login's own connection went through the proxy (allow for api.anthropic.com:443)"
else
  bad "the login's own connection went through the proxy (allow for api.anthropic.com:443)" "$(cut -f2,3 "$PLOG" 2>/dev/null | sort -u | tr '\t\n' ': ' | cut -c1-300)"
fi
if awk -F'\t' '$2 == "allow" && $4 ~ /^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.|::1$|fe80:|f[cd])/ { f = 1 } END { exit f }' "$PLOG" 2>/dev/null; then
  ok "the run's proxy log allows no loopback, private or link-local address"
else
  bad "the run's proxy log allows no loopback, private or link-local address" "$(awk -F'\t' '$2 == "allow"' "$PLOG" | cut -f3,4 | head -n 3 | tr '\t\n' ': ')"
fi

JSONL=$LOGS/$today.jsonl
init_check='select(type == "object" and .type == "system" and .subtype == "init")
  | [ ((.tools | map(tostring) | sort) == ["WebFetch", "WebSearch"]),
      (.mcp_servers == []), (.skills == []), (.apiKeySource == "none"),
      ((.model // "") | test("haiku")) ] | all'
first_init=$(jq -c 'select(type == "object") | [.type, .subtype] | tojson' "$JSONL" 2>/dev/null | head -n 1)
init_ok=$(jq -r "$init_check" "$JSONL" 2>/dev/null | head -n 1)
# the init event must come before any assistant or result event
order=$(jq -rn '[inputs | select(type == "object") | "\(.type)/\(.subtype // "")"] as $k
  | ($k | index("system/init")) as $i
  | if $i == null then "no init" elif ($k[:$i] | any(startswith("assistant/") or startswith("result/"))) then "output before init" else "ok" end' "$JSONL" 2>/dev/null)
if [ "$init_ok" = true ] && [ "$order" = ok ]; then
  ok "the saved stream's init event is the restricted one (WebFetch and WebSearch only, no MCP server or skill, the login, haiku)"
else
  bad "the saved stream's init event is the restricted one" "first event $first_init, init check: ${init_ok:-none}, order: ${order:-none}"
fi
res=$(jq -r 'select(type == "object" and .type == "result") | [(.is_error == false), (.permission_denials == []), ((.total_cost_usd // 9) < 0.5)] | all' "$JSONL" 2>/dev/null | tail -n 1)
if [ "$res" = true ]; then ok "the result is a success with no permission denial and under the 0.5 budget"
else bad "the result is a success with no permission denial and under the 0.5 budget" "result check: ${res:-none}"; fi
cost=$(jq -r 'select(type == "object" and .type == "result") | .total_cost_usd' "$JSONL" 2>/dev/null | tail -n 1)
note "model runs: $attempt; cost of the last run: \$${cost:-unknown}; last-run says cost=$(last cost)"

# nothing outside the scratch state and inbox: the scratch top level, the staged files, the
# state's and the inbox's entries, and the real config and state folders
top=$(ls -A "$S" | tr '\n' ' ')
inbox_extra=$(ls -A "$S/inbox" | grep -vxE "\.weekly-research-last-run|$today-weekly-research\.md" | tr '\n' ' ')
state_extra=$(ls -A "$S/state" | grep -vxE 'notes|failures|logs|last-run|state\.tsv' | tr '\n' ' ')
fails_left=$(ls -A "$S/state/failures" 2>/dev/null | tr '\n' ' ')
if [ "$top" = "bin config helpers inbox probe state " ] && [ "$(tree_sum)" = "$tree_before" ] \
  && [ -z "$inbox_extra" ] && [ -z "$state_extra" ] && [ -z "$fails_left" ]; then
  ok "nothing was written outside the scratch state and inbox, and no run folder or lock was left"
else
  bad "nothing was written outside the scratch state and inbox" "top: $top; inbox extra: $inbox_extra; state extra: $state_extra; failures: $fails_left"
fi
if [ "$(real_snap)" = "$real_before" ]; then
  ok "the real ~/.config/weekly-research and ~/.local/state/weekly-research were not touched"
else
  bad "the real ~/.config/weekly-research and ~/.local/state/weekly-research were not touched" "their files changed during the run"
fi

if [ "$nfail" -gt 0 ]; then exit 1; fi
if [ "$ninc" -gt 0 ]; then exit 2; fi
exit 0
