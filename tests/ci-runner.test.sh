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
is "no extra networks"    "$(yaml_get 'y.fetch("networks", nil).to_a.inspect')" '[]'
is "an older Lima refuses it" "$(yaml_get 'y["minimumLimaVersion"]')" 2.3.0
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
gate_before_runner() {
  runner=$(first_line 'apt-get .*install .*gitlab-runner')
  [ -n "$runner" ] &&
    [ "$(first_line 'put [0-9]+ /etc/systemd/system/gitlab-runner\.service\.d/10-ci-runner\.conf')" -lt "$runner" ] &&
    [ "$(first_line 'systemctl (start|reload-or-restart) ci-runner-firewall\.service')" -lt "$runner" ]
}
ok "the firewall gate is in place before the runner package is installed" gate_before_runner
ok "nftables comes with the first install" grep -Eq 'apt-get .*install .*ca-certificates curl gnupg nftables$' "$PROVISION"
upgrade_after_install() { [ "$(first_line 'apt-get .*full-upgrade')" -gt "$(first_line 'apt-get .*install .*gitlab-runner')" ]; }
ok "a fresh VM is upgraded after the install" upgrade_after_install
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

echo "E. firewall and cleanup"
cat > "$STUB/ip" <<'EOF'
#!/bin/sh
if [ "$*" = '-o route show default' ]; then printf '%s\n' "${IP_DEFAULT:-}"; fi
exit 0
EOF
cat > "$STUB/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$ROOT/nft.argv"
EOF
cat > "$STUB/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$ROOT/calls"
EOF
cat > "$STUB/docker" <<'EOF'
#!/bin/sh
case "$*" in
  'ps -aq') echo c1; exit 0 ;;
  'volume ls -q') if [ -n "${DOCKER_VOLUMES:-}" ]; then echo "$DOCKER_VOLUMES"; fi; exit 0 ;;
esac
echo "docker $*" >> "$ROOT/calls"
if [ -n "${DOCKER_FAIL:-}" ]; then
  case "$*" in "$DOCKER_FAIL"*) exit 1 ;; esac
fi
exit 0
EOF
cat > "$STUB/reboot" <<'EOF'
#!/bin/sh
echo reboot >> "$ROOT/calls"
[ "${REBOOT_FAIL:-}" = 1 ] && exit 1
exit 0
EOF
cat > "$STUB/uname" <<'EOF'
#!/bin/sh
if [ "${KERNEL_PENDING:-}" = 1 ]; then echo 6.12.3-arm64; else echo 6.12.5-arm64; fi
EOF
chmod +x "$STUB/ip" "$STUB/nft" "$STUB/systemctl" "$STUB/docker" "$STUB/reboot" "$STUB/uname"
mkdir -p "$ROOT/boot"; touch "$ROOT/boot/vmlinuz-6.12.3-arm64" "$ROOT/boot/vmlinuz-6.12.5-arm64" "$ROOT/boot/config-6.12.9-arm64"
export CI_RUNNER_BOOT="$ROOT/boot"

FW="$ROOT/ci-runner-firewall"; CLEAN="$ROOT/ci-runner-cleanup"
guest_file /usr/local/sbin/ci-runner-firewall > "$FW"; chmod +x "$FW"
guest_file /usr/local/sbin/ci-runner-cleanup > "$CLEAN"; chmod +x "$CLEAN"

nft_rules="$(guest_file /etc/ci-runner/firewall.nft)"
for r in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
  ok "blocks $r" grep -qF "$r" <<<"$nft_rules"
done
ok "a forward-hook chain of its own"    grep -Eq 'type filter hook forward priority' <<<"$nft_rules"
ok "only out through the uplink"        grep -Eq 'oifname \$uplink ip daddr .* drop' <<<"$nft_rules"
ok "forwarded IPv6 is dropped too"      grep -Eq '^[[:space:]]*oifname \$uplink meta nfproto ipv6 drop$' <<<"$nft_rules"
# a predicate, not a pipeline on the helper: a pipeline would run `no` in a subshell and lose its count
unqualified_drop() { grep -E 'drop' <<<"$nft_rules" | grep -vq 'oifname \$uplink'; }
no "a rule without the uplink qualifier" unqualified_drop
no "flushes the whole ruleset"          grep -q 'flush ruleset' <<<"$nft_rules"

PATH="$STUB:$PATH" IP_DEFAULT='default via 192.168.5.2 dev eth0 proto dhcp' "$FW"
is "the loader passes the uplink to nft" "$(cat "$ROOT/nft.argv")" '-D uplink=eth0 -f /etc/ci-runner/firewall.nft'
PATH="$STUB:$PATH" IP_DEFAULT='' "$FW" 2> /dev/null
is "no default route: the loader fails" "$?" 1

unit="$(guest_file /etc/systemd/system/ci-runner-firewall.service)"
ok "the firewall unit is a kept oneshot" grep -q '^RemainAfterExit=yes$' <<<"$unit"
ok "it loads before docker"              grep -Eq '^Before=.*docker\.service' <<<"$unit"
dropin="$(guest_file /etc/systemd/system/gitlab-runner.service.d/10-ci-runner.conf)"
ok "the runner requires the firewall"    grep -Eq '^Requires=.*ci-runner-firewall\.service' <<<"$dropin"
ok "and starts after it"                 grep -Eq '^After=.*ci-runner-firewall\.service' <<<"$dropin"
ok "the firewall unit is enabled"        grep -q 'systemctl enable ci-runner-firewall.service' "$PROVISION"
ok "a changed firewall is reloaded in place" grep -q 'systemctl reload-or-restart ci-runner-firewall.service' "$PROVISION"
ok "the unit can reload"                 grep -qx 'ExecReload=/usr/local/sbin/ci-runner-firewall' <<<"$unit"
writes_config() { grep -Eq '(put [0-9]+|>) */etc/gitlab-runner/config\.toml' "$PROVISION"; }
no "the provision script never rewrites config.toml" writes_config
last_provision_line() { [ "$(grep -v '^[[:space:]]*$' "$PROVISION" | tail -n 1)" = 'systemctl start gitlab-runner' ]; }
ok "provisioning ends by starting the runner" last_provision_line

: > "$ROOT/calls"; PATH="$STUB:$PATH" DOCKER_VOLUMES='' "$CLEAN" 2> /dev/null
is "cleanup succeeds" "$?" 0
is "cleanup order" "$(cat "$ROOT/calls")" "$(printf '%s\n' 'systemctl stop gitlab-runner' \
  'docker rm --force c1' 'docker system prune --all --force' 'docker volume prune --all --force' \
  'systemctl start gitlab-runner')"
: > "$ROOT/calls"; PATH="$STUB:$PATH" DOCKER_VOLUMES='runner-cache-1' "$CLEAN" 2> /dev/null
is "a leftover volume fails the unit"   "$?" 1
ok "and the runner is started again"    grep -qx 'systemctl start gitlab-runner' "$ROOT/calls"
: > "$ROOT/calls"; PATH="$STUB:$PATH" DOCKER_VOLUMES='' KERNEL_PENDING=1 "$CLEAN" 2> /dev/null
ok "a pending kernel reboots"           grep -qx 'reboot' "$ROOT/calls"
no "instead of starting the runner"     grep -qx 'systemctl start gitlab-runner' "$ROOT/calls"
# a failure is not hidden by a reboot: the kernel waits for the next clean week
: > "$ROOT/calls"; PATH="$STUB:$PATH" DOCKER_VOLUMES='runner-cache-1' KERNEL_PENDING=1 "$CLEAN" 2> /dev/null
is "a leftover volume with a pending kernel fails the unit" "$?" 1
no "and does not reboot"                grep -qx 'reboot' "$ROOT/calls"
ok "and the runner is started again"    grep -qx 'systemctl start gitlab-runner' "$ROOT/calls"
# every failure keeps its status and still brings the runner back
for failing in 'rm' 'system prune' 'volume prune'; do
  : > "$ROOT/calls"; PATH="$STUB:$PATH" DOCKER_VOLUMES='' DOCKER_FAIL="$failing" "$CLEAN" 2> /dev/null
  is "a failed docker $failing fails the unit"  "$?" 1
  ok "and the runner is started again ($failing)" grep -qx 'systemctl start gitlab-runner' "$ROOT/calls"
  ok "and the later steps still ran ($failing)"   grep -qx 'docker volume prune --all --force' "$ROOT/calls"
done
: > "$ROOT/calls"; PATH="$STUB:$PATH" DOCKER_VOLUMES='' KERNEL_PENDING=1 REBOOT_FAIL=1 "$CLEAN" 2> /dev/null
is "a failed reboot fails the unit"     "$?" 1
ok "and the runner is started again"    grep -qx 'systemctl start gitlab-runner' "$ROOT/calls"
clean_unit="$(guest_file /etc/systemd/system/ci-runner-cleanup.service)"
ok "the cleanup waits for provisioning" grep -qx 'After=cloud-final.service' <<<"$clean_unit"
timer="$(guest_file /etc/systemd/system/ci-runner-cleanup.timer)"
ok "weekly, at night" grep -Eq '^OnCalendar=Sun \*-\*-\* 04:00' <<<"$timer"
ok "a missed run happens at the next boot" grep -qx 'Persistent=true' <<<"$timer"

printf '\n%d/%d passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
