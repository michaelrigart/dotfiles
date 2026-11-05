#!/usr/bin/env bash
# Tests for dot_config/herdr/executable_usage.sh: the usage line in herdr's tab bar.
#
# Claude's figure comes from `tagteam status --json` (a stub on PINNED_PATH that prints a fixture,
# fails or hangs); Codex's from rollout files under a temp CODEX_HOME. HERDR_USAGE_NOW fixes the
# clock, file mtimes are set with `touch -t`, HERDR_USAGE_TRACE logs each rollout the script opens.
# Fixtures use the alias `acct`; the real tagteam and the real ~/.codex are never touched.
#
#   ./tests/herdr-usage.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SRC/dot_config/herdr/executable_usage.sh"
[ -f "$SCRIPT" ] || { echo "missing script under test: $SCRIPT" >&2; exit 2; }
[ -x /usr/bin/python3 ] || { echo "no /usr/bin/python3" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got:      %s\n    | expected: %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2" "$3"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/herdr-usage.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/empty-bin" "$T/home"
cat > "$T/bin/tagteam" <<'SH'
#!/bin/bash
[ "$*" = "status --json" ] || { echo "unexpected args: $*" >&2; exit 64; }
case "${TAGTEAM_MODE:-fixture}" in
  hang) /bin/sleep 10; exit 0 ;;
  *) /bin/cat "$TAGTEAM_FIXTURE"; exit "${TAGTEAM_RC:-0}" ;;
esac
SH
chmod 755 "$T/bin/tagteam"

NOW=1800000000
CH="$T/codex-none"
mkdir -p "$CH"
PINNED="$T/bin"
CASE=0

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
setm() { touch -t "$(date -r "$2" +%Y%m%d%H%M.%S)" "$1"; }
now_s() { /usr/bin/python3 -c 'import time; print(time.time())'; }

# A fresh CODEX_HOME with the two rollout trees, made current.
new_codex() {
  CASE=$((CASE + 1))
  CH="$T/codex-$CASE"
  mkdir -p "$CH/sessions/2027/01/15" "$CH/archived_sessions"
  TRACE="$T/trace-$CASE"
  : > "$TRACE"
}

run() { env -i HOME="$T/home" PINNED_PATH="$PINNED" CODEX_HOME="$CH" HERDR_USAGE_NOW="$NOW" "$@" "$SCRIPT" 2>"$T/stderr"; }
cl() { printf '%s' "$1" > "$T/tt.json"; run TAGTEAM_FIXTURE="$T/tt.json"; }
cx() { run TAGTEAM_MODE=none TAGTEAM_FIXTURE=/dev/null HERDR_USAGE_TRACE="$TRACE"; }

# tagteam fixtures
win() { printf '{"pct":%s,"resetsAt":"%s"}' "$1" "$(iso $((NOW + ${2:-10800})))"; }
R="\"$(iso $((NOW + 10800)))\""
usage_of() { printf '{"fiveHour":%s,"sevenDay":%s}' "$1" "$2"; }
status() { # <usage|null> <usageAge> <lastGood|null> <lastGoodAge> [alias-json]
  printf '{"active":{"alias":%s,"usage":%s,"usageAgeSeconds":%s,"lastGoodUsage":%s,"lastGoodAgeSeconds":%s,"usageStatus":"ok"}}' \
    "${5:-\"acct\"}" "$1" "$2" "$3" "$4"
}
plain() { status "$(usage_of "$(win 38.4)" "$(win 69)")" 0 null null "${1:-\"acct\"}"; }

# Codex fixtures
tc_line() { # <event-epoch> <pct> <window-minutes> <resets-epoch>
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":%s,"window_minutes":%s,"resets_at":%s},"secondary":null}}}\n' \
    "$(iso "$1")" "$2" "$3" "$4"
}
other_line() { printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"agent_message","message":"hello"}}\n' "$(iso "$1")"; }
rollout() { mkdir -p "$(dirname "$1")"; cat > "$1"; setm "$1" "$2"; }
S() { printf '%s/sessions/2027/01/15/%s' "$CH" "$1"; }
A() { printf '%s/archived_sessions/%s' "$CH" "$1"; }
RESET=$((NOW + 86400))
opened() { grep -c -F -- "$1" "$TRACE" || true; }

# ---------- Claude, from tagteam ----------
echo "claude: window choice and rounding"
is "the highest percentage among future windows wins (wk 69 over 5h 38.4)" "$(cl "$(plain)")" "acct 69% wk"
is "a higher 5h window beats a lower wk" "$(cl "$(status "$(usage_of "$(win 90)" "$(win 40)")" 0 null null)")" "acct 90% 5h ⚠"
is "fiveHour null falls to sevenDay" "$(cl "$(status "$(usage_of null "$(win 69)")" 0 null null)")" "acct 69% wk"
is "a window that has reset is ignored" "$(cl "$(status "$(usage_of "$(win 90 -60)" "$(win 40)")" 0 null null)")" "acct 40% wk"
is "every window reset prints a dash" "$(cl "$(status "$(usage_of "$(win 90 -60)" "$(win 40 -1)")" 0 null null)")" "acct —"
is "both windows null prints a dash" "$(cl "$(status "$(usage_of null null)" 0 null null)")" "acct —"
is "pct 80 carries the warning" "$(cl "$(status "$(usage_of null "$(win 80)")" 0 null null)")" "acct 80% wk ⚠"
is "pct 79.6 rounds to 80 without the warning (it follows the raw value)" "$(cl "$(status "$(usage_of null "$(win 79.6)")" 0 null null)")" "acct 80% wk"
is "pct 0 prints 0%" "$(cl "$(status "$(usage_of null "$(win 0)")" 0 null null)")" "acct 0% wk"

echo "claude: age marks"
age_case() { cl "$(status "$(usage_of null "$(win 69)")" "$1" null null)"; }
is "age 2400 s shows 40m" "$(age_case 2400)" "acct 69% wk ·40m"
is "age 7200 s shows 2h" "$(age_case 7200)" "acct 69% wk ·2h"
is "age exactly 1800 s shows no mark" "$(age_case 1800)" "acct 69% wk"
is "age 1801 s shows 30m (floored)" "$(age_case 1801)" "acct 69% wk ·30m"
is "age 3599 s shows 59m" "$(age_case 3599)" "acct 69% wk ·59m"
is "age 3600 s shows 1h" "$(age_case 3600)" "acct 69% wk ·1h"
is "age 172799 s shows 47h" "$(age_case 172799)" "acct 69% wk ·47h"
is "age 172800 s shows 2d" "$(age_case 172800)" "acct 69% wk ·2d"
is "the warning comes before the age mark" "$(cl "$(status "$(usage_of null "$(win 90)")" 7200 null null)")" "acct 90% wk ⚠ ·2h"

echo "claude: lastGoodUsage and missing figures"
is "usage null + lastGoodUsage: figure shown with its age mark even at 120 s" \
  "$(cl "$(status null 0 "$(usage_of null "$(win 55)")" 120)")" "acct 55% wk ·2m"
is "lastGoodUsage with all windows reset prints a dash" \
  "$(cl "$(status null 0 "$(usage_of null "$(win 55 -5)")" 120)")" "acct —"
is "usage non-null wins over lastGoodUsage" \
  "$(cl "$(status "$(usage_of null "$(win 10)")" 0 "$(usage_of null "$(win 55)")" 9000)")" "acct 10% wk"
is "usage and lastGoodUsage both null (token_expired) print a dash" \
  "$(cl '{"active":{"alias":"acct","usage":null,"usageAgeSeconds":null,"lastGoodUsage":null,"lastGoodAgeSeconds":null,"usageStatus":"token_expired"}}')" "acct —"

echo "claude: a window with no reset time ends with its own length"
bare() { printf '{"pct":%s}' "$1"; }
lg_five() { cl "$(status null 0 "$(usage_of "$(bare 90)" null)" "$1")"; }
is "lastGood fiveHour without resetsAt, 1h old: still shown" "$(lg_five 3600)" "acct 90% 5h ⚠ ·1h"
is "lastGood fiveHour without resetsAt, exactly 5h old: still shown" "$(lg_five 18000)" "acct 90% 5h ⚠ ·5h"
is "lastGood fiveHour without resetsAt, 6h old: treated as reset, dash" "$(lg_five 21600)" "acct —"
is "lastGood sevenDay without resetsAt, 6d old: still shown" \
  "$(cl "$(status null 0 "$(usage_of null "$(bare 70)")" 518400)")" "acct 70% wk ·6d"
is "lastGood sevenDay without resetsAt, 8d old: dash" \
  "$(cl "$(status null 0 "$(usage_of null "$(bare 70)")" 691200)")" "acct —"
is "usage fiveHour without resetsAt, 6h old: dash" \
  "$(cl "$(status "$(usage_of "$(bare 90)" null)" 21600 null null)")" "acct —"
is "an expired no-reset window yields to a live one" \
  "$(cl "$(status null 0 "$(usage_of "$(bare 90)" "$(bare 40)")" 21600)")" "acct 40% wk ·6h"
is "a known future resetsAt is not cut short by the figure's age" \
  "$(cl "$(status "$(usage_of "$(win 90 100000)" null)" 21600 null null)")" "acct 90% 5h ⚠ ·6h"

echo "claude: an unknown age is marked ·?"
is "usageAgeSeconds missing: ·?" "$(cl '{"active":{"alias":"acct","usage":{"sevenDay":{"pct":40,"resetsAt":'"$R"'}}}}')" "acct 40% wk ·?"
is "usageAgeSeconds a string: ·?" "$(cl '{"active":{"alias":"acct","usage":{"sevenDay":{"pct":40,"resetsAt":'"$R"'}},"usageAgeSeconds":"old"}}')" "acct 40% wk ·?"
is "usageAgeSeconds null: ·?" "$(cl '{"active":{"alias":"acct","usage":{"sevenDay":{"pct":40,"resetsAt":'"$R"'}},"usageAgeSeconds":null}}')" "acct 40% wk ·?"
is "usageAgeSeconds negative: ·?" "$(cl '{"active":{"alias":"acct","usage":{"sevenDay":{"pct":40,"resetsAt":'"$R"'}},"usageAgeSeconds":-5}}')" "acct 40% wk ·?"
is "lastGoodAgeSeconds missing: ·? (not a fresh-looking ·0m)" "$(cl '{"active":{"alias":"acct","usage":null,"lastGoodUsage":{"sevenDay":{"pct":40,"resetsAt":'"$R"'}}}}')" "acct 40% wk ·?"
is "lastGoodAgeSeconds a string: ·?" "$(cl '{"active":{"alias":"acct","usage":null,"lastGoodUsage":{"sevenDay":{"pct":40,"resetsAt":'"$R"'}},"lastGoodAgeSeconds":"x"}}')" "acct 40% wk ·?"
is "the warning still precedes ·?" "$(cl '{"active":{"alias":"acct","usage":{"sevenDay":{"pct":85,"resetsAt":'"$R"'}}}}')" "acct 85% wk ⚠ ·?"
is "unknown age and no reset time: cannot show the figure, dash" "$(cl '{"active":{"alias":"acct","usage":{"sevenDay":{"pct":40}}}}')" "acct —"
is "no usable window: a dash carries no age mark" "$(cl '{"active":{"alias":"acct","usage":{"sevenDay":{"pct":"x"}}}}')" "acct —"

echo "claude: label and absence"
is "tagteam's non-usage shape (email/provider, no usage keys): claude dash" \
  "$(cl '{"active":{"email":"someone@example.invalid","provider":"claude","managed":false}}')" "claude —"
is "the same shape with an alias: alias dash" \
  "$(cl '{"active":{"alias":"acct","email":"someone@example.invalid","provider":"claude","managed":false}}')" "acct —"
is "active null: no Claude segment" "$(cl '{"active":null}')" ""
is "no alias key: label claude" "$(cl '{"active":{"usage":{"fiveHour":null,"sevenDay":'"$(win 69)"'},"usageAgeSeconds":0}}')" "claude 69% wk"
is "alias null: label claude" "$(cl "$(plain null)")" "claude 69% wk"
is "alias empty: label claude" "$(cl "$(plain '""')")" "claude 69% wk"
PINNED="$T/empty-bin"
out="$(run)"; rc=$?
is "tagteam missing: no Claude segment, exit 0" "$out|$rc" "|0"
PINNED="$T/bin"
printf '%s' "$(plain)" > "$T/tt.json"
out="$(run TAGTEAM_FIXTURE="$T/tt.json" TAGTEAM_RC=1)"; rc=$?
is "tagteam exiting 1: no Claude segment, exit 0" "$out|$rc" "|0"
out="$(cl 'this is not json {')"; rc=$?
is "tagteam printing garbage: no Claude segment, exit 0" "$out|$rc" "|0"
is "garbage leaves stderr empty" "$(cat "$T/stderr")" ""
out="$(cl '')"; rc=$?
is "tagteam printing nothing: no Claude segment, exit 0" "$out|$rc" "|0"
is "empty output leaves stderr empty" "$(cat "$T/stderr")" ""

echo "claude: a hung tagteam"
new_codex
{ other_line $((NOW - 600)); tc_line $((NOW - 600)) 82 10080 "$RESET"; } | rollout "$(S rollout-a.jsonl)" $((NOW - 600))
t0="$(now_s)"
out="$(run TAGTEAM_MODE=hang)"; rc=$?
t1="$(now_s)"
is "hung tagteam: the Codex segment still prints, exit 0" "$out|$rc" "codex 82% wk ⚠|0"
fast="$(/usr/bin/python3 -c "import sys; print('yes' if float(sys.argv[2]) - float(sys.argv[1]) < 4.0 else 'no')" "$t0" "$t1")"
is "hung tagteam: the script returns within 4 s" "$fast" "yes"

# ---------- Codex, from rollouts ----------
echo "codex: finding the reading"
new_codex
{ other_line $((NOW - 50)); } | rollout "$(S rollout-new.jsonl)" $((NOW - 50))
{ other_line $((NOW - 900)); tc_line $((NOW - 900)) 61 10080 "$RESET"; other_line $((NOW - 800)); } | rollout "$(S rollout-old.jsonl)" $((NOW - 800))
is "newest file has no token_count: the older file's reading shows" "$(cx)" "codex 61% wk"

new_codex
for i in 1 2 3 4 5; do other_line $((NOW - i)) | rollout "$(S rollout-empty$i.jsonl)" $((NOW - i)); done
{ tc_line $((NOW - 3000)) 47 10080 "$RESET"; } | rollout "$(S rollout-real.jsonl)" $((NOW - 3000))
is "five newer files without a reading do not hide it (aged 50m)" "$(cx)" "codex 47% wk ·50m"

new_codex
tc_line $((NOW - 3000)) 30 10080 "$RESET" | rollout "$(S rollout-s.jsonl)" $((NOW - 3000))
tc_line $((NOW - 600)) 71 10080 "$RESET" | rollout "$(A rollout-arch.jsonl)" $((NOW - 600))
is "an archived rollout with a newer event beats anything under sessions" "$(cx)" "codex 71% wk"

new_codex
tc_line $((NOW - 600)) 30 10080 "$RESET" | rollout "$(S rollout-s.jsonl)" $((NOW - 600))
tc_line $((NOW - 3000)) 71 10080 "$RESET" | rollout "$(A rollout-arch.jsonl)" $((NOW - 3000))
is "a sessions rollout with a newer event beats an archived one" "$(cx)" "codex 30% wk"

new_codex
{ tc_line $((NOW - 7000)) 20 10080 "$RESET"; tc_line $((NOW - 200)) 33 10080 "$RESET"; printf '{"truncated\n'; printf 'not json at all\n'; } | rollout "$(S rollout-a.jsonl)" $((NOW - 100))
is "the last token_count wins; malformed lines are skipped" "$(cx)" "codex 33% wk"

new_codex
{ tc_line $((NOW - 7000)) 20 10080 "$RESET"
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}\n' "$(iso $((NOW - 60)))"
} | rollout "$(S rollout-a.jsonl)" $((NOW - 60))
is "a later token_count with null rate_limits is passed over" "$(cx)" "codex 20% wk ·1h"

new_codex
{ printf '{"timestamp":"not a time","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":99,"window_minutes":10080,"resets_at":%s}}}}\n' "$RESET"
  tc_line $((NOW - 120)) 20 10080 "$RESET"
} | rollout "$(S rollout-a.jsonl)" $((NOW - 60))
is "a token_count without a valid timestamp is not an observation" "$(cx)" "codex 20% wk"

echo "codex: when the walk stops"
new_codex
tc_line $((NOW - 100)) 50 10080 "$RESET" | rollout "$(S rollout-a.jsonl)" $((NOW - 100))
tc_line $((NOW - 5000)) 90 10080 "$RESET" | rollout "$(S rollout-b.jsonl)" $((NOW - 5000))
is "the newer event's figure shows" "$(cx)" "codex 50% wk"
is "the file read first is traced" "$(opened rollout-a.jsonl)" "1"
is "a file whose mtime is older than the newest event is never opened" "$(opened rollout-b.jsonl)" "0"

new_codex
tc_line $((NOW - 600)) 50 10080 "$RESET" | rollout "$(S rollout-a.jsonl)" $((NOW - 100))
tc_line $((NOW - 700)) 60 10080 "$RESET" | rollout "$(S rollout-b.jsonl)" $((NOW - 600))
tc_line $((NOW - 900)) 99 10080 "$RESET" | rollout "$(S rollout-c.jsonl)" $((NOW - 800))
cx > /dev/null
is "a file whose mtime is not older than the newest event is still opened" "$(opened rollout-b.jsonl)" "1"
is "the walk stops at the first file older than the newest event" "$(opened rollout-c.jsonl)" "0"

new_codex
tc_line $((NOW - 8 * 86400)) 50 10080 "$((NOW + 86400))" | rollout "$(S rollout-old.jsonl)" $((NOW - 8 * 86400))
out="$(cx)"
is "a file older than 7 days gives no Codex segment" "$out" ""
is "a file older than 7 days is never opened" "$(opened rollout-old.jsonl)" "0"
new_codex
tc_line $((NOW - 6 * 86400)) 50 10080 "$((NOW + 86400))" | rollout "$(S rollout-six.jsonl)" $((NOW - 6 * 86400))
is "a file 6 days old is read (aged 6d)" "$(cx)" "codex 50% wk ·6d"
is "a file 6 days old is traced" "$(opened rollout-six.jsonl)" "1"

new_codex
other_line $((NOW - 10)) | rollout "$(S rollout-a.jsonl)" $((NOW - 10))
is "rollouts without any token_count: no Codex segment" "$(cx)" ""
new_codex
is "no rollouts at all: empty line" "$(cx)" ""

echo "codex: large and awkward files"
new_codex
/usr/bin/python3 - "$(S rollout-big.jsonl)" "$(iso $((NOW - 90)))" "$RESET" <<'PY'
import sys
path, ts, reset = sys.argv[1:4]
tc = ('{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":'
      '{"primary":{"used_percent":44.0,"window_minutes":10080,"resets_at":%s},"secondary":null}}}\n' % (ts, reset))
other = '{"timestamp":"%s","type":"event_msg","payload":{"type":"agent_message","message":"%s"}}\n'
with open(path, "w") as f:
    f.write(tc)
    f.write(other % (ts, "y" * 150000))
    for _ in range(3500):
        f.write(other % (ts, "z" * 250))
PY
setm "$(S rollout-big.jsonl)" $((NOW - 90))
size="$(wc -c < "$(S rollout-big.jsonl)" | tr -d ' ')"
is "far token_count: the fixture is about 1 MB" "$([ "$size" -gt 1000000 ] && echo big || echo small:$size)" "big"
is "far token_count: found in a file's first KiB past a line longer than a chunk" "$(cx)" "codex 44% wk"
reads="$(grep -c '^read ' "$TRACE" || true)"
biggest="$(awk '$1 == "read" && $2 > m { m = $2 } END { print m + 0 }' "$TRACE")"
is "far token_count: the 1 MB file is read in at least 16 chunks" "$([ "$reads" -ge 16 ] && echo ok || echo "only $reads reads")" "ok"
is "far token_count: no single read exceeds 64 KiB (a whole-file read would)" "$([ "$biggest" -gt 0 ] && [ "$biggest" -le 65536 ] && echo ok || echo "largest read $biggest bytes")" "ok"

for pad in 65236 65336 65436 65535 65536 65700 131072; do
  new_codex
  /usr/bin/python3 - "$(S rollout-a.jsonl)" "$(iso $((NOW - 90)))" "$RESET" "$pad" <<'PY'
import sys
path, ts, reset, pad = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
tc = ('{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":'
      '{"primary":{"used_percent":44.0,"window_minutes":10080,"resets_at":%s},"secondary":null}}}\n' % (ts, reset))
with open(path, "w") as f:
    f.write(tc)
    f.write("x" * pad + "\n")
PY
  setm "$(S rollout-a.jsonl)" $((NOW - 90))
  is "a token_count line straddling a chunk boundary is read whole (pad $pad)" "$(cx)" "codex 44% wk"
done

echo "codex: windows and labels"
label_case() { # <window-minutes>
  new_codex
  tc_line $((NOW - 60)) 50 "$1" "$RESET" | rollout "$(S rollout-a.jsonl)" $((NOW - 60))
  cx
}
is "window_minutes 10080 is wk" "$(label_case 10080)" "codex 50% wk"
is "window_minutes 300 is 5h" "$(label_case 300)" "codex 50% 5h"
is "window_minutes 1440 is 1d" "$(label_case 1440)" "codex 50% 1d"
is "window_minutes 120 is 2h" "$(label_case 120)" "codex 50% 2h"
is "window_minutes 45 is 45m" "$(label_case 45)" "codex 50% 45m"
new_codex
printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":30,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":60,"window_minutes":10080,"resets_at":%s}}}}\n' \
  "$(iso $((NOW - 60)))" "$RESET" "$RESET" | rollout "$(S rollout-a.jsonl)" $((NOW - 60))
is "the higher of primary and secondary wins" "$(cx)" "codex 60% wk"
new_codex
printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":30,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":60,"window_minutes":10080,"resets_at":%s}}}}\n' \
  "$(iso $((NOW - 60)))" "$RESET" "$((NOW - 1))" | rollout "$(S rollout-a.jsonl)" $((NOW - 60))
is "a window that has reset is ignored" "$(cx)" "codex 30% 5h"
new_codex
tc_line $((NOW - 60)) 90 10080 "$((NOW - 1))" | rollout "$(S rollout-a.jsonl)" $((NOW - 60))
is "every Codex window reset prints a dash" "$(cx)" "codex —"
noreset_case() { # <window-minutes> <event age in seconds>
  new_codex
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":50,"window_minutes":%s},"secondary":null}}}\n' \
    "$(iso $((NOW - $2)))" "$1" | rollout "$(S rollout-a.jsonl)" $((NOW - $2))
  cx
}
is "Codex window without resets_at, event 1h old (300 min window): shown" "$(noreset_case 300 3600)" "codex 50% 5h ·1h"
is "Codex window without resets_at, event 6h old (300 min window): treated as reset, dash" "$(noreset_case 300 21600)" "codex —"
is "Codex window without resets_at, event 6h old (10080 min window): shown" "$(noreset_case 10080 21600)" "codex 50% wk ·6h"
new_codex
tc_line $((NOW - 3 * 3600)) 82 10080 "$RESET" | rollout "$(S rollout-a.jsonl)" $((NOW - 3 * 3600))
is "Codex age comes from the event timestamp (3h) with the warning" "$(cx)" "codex 82% wk ⚠ ·3h"
new_codex
tc_line $((NOW - 3 * 3600)) 82 10080 "$RESET" | rollout "$(S rollout-a.jsonl)" $((NOW - 60))
is "Codex age ignores the file mtime" "$(cx)" "codex 82% wk ⚠ ·3h"

# ---------- both ----------
echo "both agents and width"
new_codex
tc_line $((NOW - 60)) 82 10080 "$RESET" | rollout "$(S rollout-a.jsonl)" $((NOW - 60))
is "Claude first, then Codex, joined by ' · '" "$(cl "$(plain)")" "acct 69% wk · codex 82% wk ⚠"
is "stderr is empty on the happy path" "$(cat "$T/stderr")" ""
new_codex
tc_line $((NOW - 3 * 3600)) 82 10080 "$RESET" | rollout "$(S rollout-a.jsonl)" $((NOW - 3 * 3600))
out="$(cl "$(status "$(usage_of null "$(win 69)")" 2400 null null)")"
is "both agents with age marks and the warning" "$out" "acct 69% wk ·40m · codex 82% wk ⚠ ·3h"
len="$(printf '%s' "$out" | /usr/bin/python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8")))')"
is "width: the longest realistic line is at most 40 characters" "$([ "$len" -le 40 ] && echo ok || echo "too wide: $len")" "ok"
is "width: it is the 37-cell line the plan measured" "$len" "37"

# ---------- malformed input ----------
echo "malformed tagteam fields"
CH="$T/codex-none"
SHAPE='^([^ ]+ (-|[0-9]+% [^ ]+( !)?( \.([0-9]+[mhd]|\?))?))?$'
shape_ok() { # <name> <fixture-json>
  local out norm
  out="$(cl "$2")"; local rc=$?
  norm="$(printf '%s' "$out" | LC_ALL=C sed -e 's/⚠/!/g' -e 's/·/./g' -e 's/—/-/g')"
  if [ "$rc" -eq 0 ] && [ ! -s "$T/stderr" ] && printf '%s\n' "$norm" | LC_ALL=C grep -Eq "$SHAPE"; then
    _pass "$1 -> '$out'"
  else
    _fail "$1" "rc=$rc out='$out' stderr='$(head -c 200 "$T/stderr")'" "a documented shape, empty stderr, exit 0"
  fi
}
is "string pct is skipped: dash" "$(cl '{"active":{"alias":"acct","usage":{"fiveHour":{"pct":"high","resetsAt":'"$R"'},"sevenDay":null},"usageAgeSeconds":0}}')" "acct —"
is "a window without resetsAt is not known to have reset: it shows" "$(cl '{"active":{"alias":"acct","usage":{"fiveHour":{"pct":38.4},"sevenDay":null},"usageAgeSeconds":0}}')" "acct 38% 5h"
shape_ok "pct true" '{"active":{"alias":"acct","usage":{"fiveHour":{"pct":true,"resetsAt":'"$R"'}}}}'
shape_ok "pct null" '{"active":{"alias":"acct","usage":{"fiveHour":{"pct":null,"resetsAt":'"$R"'}}}}'
shape_ok "pct NaN" '{"active":{"alias":"acct","usage":{"fiveHour":{"pct":NaN,"resetsAt":'"$R"'}}}}'
shape_ok "pct infinite" '{"active":{"alias":"acct","usage":{"fiveHour":{"pct":1e999,"resetsAt":'"$R"'}}}}'
shape_ok "pct negative" '{"active":{"alias":"acct","usage":{"fiveHour":{"pct":-5,"resetsAt":'"$R"'}}}}'
shape_ok "pct absurd" '{"active":{"alias":"acct","usage":{"fiveHour":{"pct":1e300,"resetsAt":'"$R"'}}}}'
shape_ok "resetsAt a number" '{"active":{"alias":"acct","usage":{"fiveHour":{"pct":40,"resetsAt":12}}}}'
shape_ok "resetsAt garbage" '{"active":{"alias":"acct","usage":{"fiveHour":{"pct":40,"resetsAt":"later"}}}}'
shape_ok "resetsAt year 9999999" '{"active":{"alias":"acct","usage":{"fiveHour":{"pct":40,"resetsAt":"99999-01-01T00:00:00Z"}}}}'
shape_ok "usage a string" '{"active":{"alias":"acct","usage":"x"}}'
shape_ok "usage a list" '{"active":{"alias":"acct","usage":[1,2]}}'
shape_ok "fiveHour a string" '{"active":{"alias":"acct","usage":{"fiveHour":"x","sevenDay":7}}}'
shape_ok "usageAgeSeconds a string" '{"active":{"alias":"acct","usage":{"sevenDay":{"pct":40}},"usageAgeSeconds":"old"}}'
shape_ok "usageAgeSeconds negative" '{"active":{"alias":"acct","usage":{"sevenDay":{"pct":40}},"usageAgeSeconds":-9999}}'
shape_ok "lastGoodAgeSeconds missing" '{"active":{"alias":"acct","usage":null,"lastGoodUsage":{"sevenDay":{"pct":40}}}}'
shape_ok "lastGoodUsage a string" '{"active":{"alias":"acct","usage":null,"lastGoodUsage":"x"}}'
shape_ok "alias a number" '{"active":{"alias":5,"usage":null,"lastGoodUsage":null}}'
shape_ok "alias with a newline" '{"active":{"alias":"a\nb","usage":null,"lastGoodUsage":null}}'
shape_ok "active a string" '{"active":"x"}'
shape_ok "top level a list" '[]'
shape_ok "top level null" 'null'
is "a missing resetsAt on a stale lastGoodUsage still carries the age mark" "$(cl '{"active":{"alias":"acct","usage":null,"lastGoodUsage":{"sevenDay":{"pct":40}},"lastGoodAgeSeconds":300}}')" "acct 40% wk ·5m"
is "alias with a newline falls back to claude" "$(cl '{"active":{"alias":"a\nb","usage":null,"lastGoodUsage":null}}')" "claude —"

total=$((pass + fail))
echo "$pass/$total passed"
[ "$fail" -eq 0 ]
