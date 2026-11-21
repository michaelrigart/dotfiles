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
no "an unquoted here-document" grep -Eq '(^|[^<])<<-?[[:space:]]*[A-Za-z_]' "$PROVISION"

STUB="$ROOT/stub"; mkdir -p "$STUB"
cat > "$STUB/gitlab-runner" <<'EOF'
#!/bin/sh
echo "$*" >> "$ROOT/argv"
printf '%s' "${CI_SERVER_TOKEN:-}" > "$ROOT/env.token"
printf '%s' "${CI_SERVER_URL:-}" > "$ROOT/env.url"
EOF
chmod +x "$STUB/gitlab-runner"
export ROOT

CONC="$ROOT/ci-runner-concurrency"; REG="$ROOT/ci-runner-register"
guest_file /usr/local/sbin/ci-runner-concurrency > "$CONC"; chmod +x "$CONC"
guest_file /usr/local/sbin/ci-runner-register > "$REG"; chmod +x "$REG"

echo "B. concurrency"
f="$ROOT/absent.toml"; "$CONC" "$f"
is "an absent config is created" "$(cat "$f" 2>/dev/null)" 'concurrent = 2'
is "and is private to its owner" "$(stat -f %Lp "$f")" 600
printf 'concurrent = 1\ncheck_interval = 0\n\n[[runners]]\n  name = "ci"\n  token = "glrt-fixture"\n' > "$ROOT/reg.toml"
"$CONC" "$ROOT/reg.toml"; "$CONC" "$ROOT/reg.toml"
is "concurrent is 2"            "$(grep -c '^concurrent = 2$' "$ROOT/reg.toml")" 1
is "nothing else changed"       "$(grep -v '^concurrent' "$ROOT/reg.toml" | shasum | cut -d' ' -f1)" \
                                "$(printf 'check_interval = 0\n\n[[runners]]\n  name = "ci"\n  token = "glrt-fixture"\n' | shasum | cut -d' ' -f1)"
printf '[[runners]]\n  token = "glrt-fixture"\n' > "$ROOT/noline.toml"; "$CONC" "$ROOT/noline.toml"
is "a missing line is added first" "$(head -1 "$ROOT/noline.toml")" 'concurrent = 2'

echo "C. registration"
printf 'glrt-fixture\n' > "$ROOT/tty"; : > "$ROOT/cfg.toml"
PATH="$STUB:$PATH" CI_RUNNER_TTY="$ROOT/tty" CI_RUNNER_CONFIG="$ROOT/cfg.toml" "$REG" > /dev/null 2>&1; rc=$?
is "register succeeds"            "$rc" 0
is "the token is in the environment" "$(cat "$ROOT/env.token" 2>/dev/null)" glrt-fixture
no "the token is in argv"         grep -q glrt-fixture "$ROOT/argv"
is "the server"                   "$(cat "$ROOT/env.url" 2>/dev/null)" https://gitlab.com
for flag in '--non-interactive' '--executor docker' '--docker-privileged=false' \
  '--docker-pull-policy if-not-present' '--docker-memory 2500m' '--docker-cpus 2' \
  '--docker-service-memory 1g' '--docker-service-cpus 1' '--docker-dns 1.1.1.1' '--docker-dns 9.9.9.9'; do
  ok "register passes $flag" grep -qF -- "$flag" "$ROOT/argv"
done
no "register adds a volume or socket" grep -Eq -- '--docker-volumes|docker\.sock' "$REG"
no "register can lift privileged"     grep -Eq -- 'privileged(=| )true' "$REG"
printf '\n' > "$ROOT/tty"; : > "$ROOT/cfg.toml"
PATH="$STUB:$PATH" CI_RUNNER_TTY="$ROOT/tty" CI_RUNNER_CONFIG="$ROOT/cfg.toml" "$REG" > /dev/null 2>&1
is "an empty token is refused" "$?" 1
printf '  glrt-spaced \t\n' > "$ROOT/tty"; : > "$ROOT/cfg.toml"
PATH="$STUB:$PATH" CI_RUNNER_TTY="$ROOT/tty" CI_RUNNER_CONFIG="$ROOT/cfg.toml" "$REG" > /dev/null 2>&1
is "whitespace around the token is stripped" "$(cat "$ROOT/env.token" 2>/dev/null)" glrt-spaced
printf 'glrt-other\n' > "$ROOT/tty"; printf '[[runners]]\n' > "$ROOT/cfg.toml"; : > "$ROOT/argv"
PATH="$STUB:$PATH" CI_RUNNER_TTY="$ROOT/tty" CI_RUNNER_CONFIG="$ROOT/cfg.toml" "$REG" > /dev/null 2>&1
is "a registered runner is not registered again" "$?" 1
is "and gitlab-runner was not called"            "$(wc -c < "$ROOT/argv" | tr -d ' ')" 0

echo "D. apt"
first_line() { grep -nE "$1" "$PROVISION" | head -1 | cut -d: -f1; }
tools_before_fetch() { [ "$(first_line 'apt-get .*install .*ca-certificates curl gnupg')" -lt "$(first_line '(curl|gpg) .*(download\.docker\.com|packages\.gitlab\.com)')" ]; }
ok "curl, gpg and certificates are installed before a key is fetched" tools_before_fetch
docker_source() {
  src="$(guest_file /etc/apt/sources.list.d/docker.sources)" || return 1
  grep -qxF 'URIs: https://download.docker.com/linux/debian' <<<"$src" &&
    grep -qxF 'Signed-By: /etc/apt/keyrings/docker.asc' <<<"$src"
}
ok "docker repository"  docker_source
runner_source() {
  src="$(guest_file /etc/apt/sources.list.d/runner_gitlab-runner.list)" || return 1
  grep -qF 'signed-by=/etc/apt/keyrings/runner_gitlab-runner-archive-keyring.gpg' <<<"$src" &&
    grep -qF 'https://packages.gitlab.com/runner/gitlab-runner/debian' <<<"$src"
}
ok "runner repository"  runner_source
u="$(guest_file /etc/apt/apt.conf.d/52unattended-upgrades-local)"
ok "docker upgrades unattended" grep -qF 'origin=Docker' <<<"$u"
ok "runner upgrades unattended" grep -qF 'origin=packages.gitlab.com/runner/gitlab-runner' <<<"$u"

printf '\n%d/%d passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
