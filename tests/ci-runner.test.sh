#!/usr/bin/env bash
# Tests for dot_config/ci-runner/lima.yaml, the Lima VM of the personal GitLab CI runner
# (spec 2026-11-21-personal-ci-runner-design section 2). Pins its safety settings and runs
# its provision script's guest files against stubs; nothing is installed or started.
#
#   ./tests/ci-runner.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$SRC/dot_config/ci-runner/lima.yaml"
[ -f "$TPL" ] || { echo "missing template under test: $TPL" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }
ok() { if "${@:2}"; then _pass "$1"; else _fail "$1" "$*"; fi; }
no() { if "${@:2}"; then _fail "$1" "$*"; else _pass "$1"; fi; }

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ci-runner.XXXXXX")" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

# yaml_get <ruby-expr>: the value of the expression over the parsed template, bound to y
yaml_get() { /usr/bin/ruby -ryaml -e 'y = YAML.safe_load(File.read(ARGV[0])); puts(eval(ARGV[1]))' "$TPL" "$1"; }

PROVISION="$ROOT/provision.sh"
yaml_get 'y["provision"].map { |p| p["script"] }.join("\n")' > "$PROVISION"

# guest_file <guest-path>: the body of the here-document the provision script writes to that
# path with `put <mode> <path> <<'EOF'`; returns 1 when the script writes no such path
guest_file() {
  awk -v want="$1" '
    !inside && $1 == "put" && $3 == want && $0 ~ /<<'\''EOF'\''/ { inside = 1; found = 1; next }
    inside && $0 == "EOF" { inside = 0; next }
    inside { print }
    END { exit !found }
  ' "$PROVISION"
}

echo "A. the template"
is "vz"                   "$(yaml_get 'y["vmType"]')" vz
is "plain mode"           "$(yaml_get 'y["plain"]')" true
is "no mounts"            "$(yaml_get 'y["mounts"].inspect')" '[]'
is "no agent forwarding"  "$(yaml_get 'y["ssh"]["forwardAgent"]')" false
is "host loopback off"    "$(yaml_get 'y["networkOpts"]["hostLoopback"]')" false
is "4 cpus"               "$(yaml_get 'y["cpus"]')" 4
is "8 GiB"                "$(yaml_get 'y["memory"]')" 8GiB
is "60 GiB"               "$(yaml_get 'y["disk"]')" 60GiB
is "arm64 only"           "$(yaml_get 'y["images"].map { |i| i["arch"] }.uniq.join(",")')" aarch64
is "every image pinned"   "$(yaml_get 'y["images"].all? { |i| i["digest"].to_s.start_with?("sha512:") }')" true
is "no port forwards"     "$(yaml_get 'y.fetch("portForwards", []).inspect')" '[]'
is "one provision script" "$(yaml_get 'y["provision"].map { |p| p["mode"] }.join(",")')" system
ok "the script parses"    bash -n "$PROVISION"
no "an unquoted here-document" grep -Eq '<<-?[A-Za-z_]' "$PROVISION"

printf '\n%d/%d passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
