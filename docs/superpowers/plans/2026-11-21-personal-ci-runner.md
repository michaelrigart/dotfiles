# Personal CI Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress (branch `feat/personal-ci-runner`)

**Goal:** Ship the Lima VM template, its safety-pin suite and the host wiring for a GitLab project
runner on hercules; nothing is installed or registered by this plan.

**Architecture:** One Lima template, `dot_config/ci-runner/lima.yaml`, whose single system
provision script writes every guest file from quoted here-documents (firewall table and unit,
runner drop-in, three small scripts, cleanup timer, apt settings). One bash suite parses the
template, pins its settings, and runs the three guest scripts against stubs. The host side is one
Brewfile line, one `zshenv` export and one `AGENTS.md` rule.

**Tech Stack:** Lima 2.3 YAML (`vmType: vz`), bash, nftables, systemd units, Debian 13 guest;
tests in bash with `/usr/bin/ruby -ryaml` to parse the template.

**Spec:** `docs/superpowers/specs/2026-11-21-personal-ci-runner-design.md` (signed 2026-11-21).
Sections cited below as S1 to S7.

## Global Constraints

- This repository is public: no token, project ID, address of Michael's network, or private
  project name beyond `curato` appears in any file.
- Nothing is installed, started or registered anywhere. `limactl` is not on this machine and no
  task may install it; no task contacts hercules or GitLab.
- The template's safety values, verbatim: `vmType: vz`, `plain: true`, `mounts: []`,
  `ssh.forwardAgent: false`, `networkOpts.hostLoopback: false`, `cpus: 4`, `memory: 8GiB`,
  `disk: 60GiB`.
- Runner values, verbatim: `concurrent = 2`; `--docker-privileged=false`,
  `--docker-pull-policy if-not-present`, `--docker-memory 2500m`, `--docker-cpus 2`,
  `--docker-service-memory 1g`, `--docker-service-cpus 1`, `--docker-dns 1.1.1.1`,
  `--docker-dns 9.9.9.9`; no `--docker-volumes`, no Docker socket anywhere.
- Firewall ranges, verbatim: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`,
  `169.254.0.0/16`, dropped only for packets forwarded out through the uplink interface.
- Every here-document in the provision script is quoted (`<<'EOF'`), so nothing expands while
  the files are written, and every step of the script is safe to run on every boot.
- Guest scripts use only POSIX `sed`/`grep`/`awk` features that behave the same on macOS, since
  the suite runs them here. No `sed -i`.
- Suites: read `tests/AGENTS.md` first. Execute `./tests/ci-runner.test.sh`, never
  `bash tests/…`. The suite exits 2 when the template is missing. No comment cites a review
  round or a task.
- Commit messages: imperative mood, no attribution lines. Check `git branch --show-current`
  prints `feat/personal-ci-runner` before each commit.

## Review Focus

- A reboot before the firewall can load (no default route yet, or a broken rules file): the
  runner must not start. Pinned in Task 3 (the loader fails without a default route; the drop-in
  requires the unit).
- A second run of `ci-runner-register`, or a run after the token line exists: it must refuse,
  not append a second runner. Pinned in Task 2.
- `config.toml` holding a registered runner when provisioning runs again on boot: the token and
  every `[[runners]]` line survive byte for byte. Pinned in Task 2.
- The cleanup finding a volume it cannot remove: it exits non-zero and still restarts the
  runner, so a failed cleanup is visible and CI is not left down. Pinned in Task 3.
- A token typed with surrounding whitespace or an empty line: the register script refuses an
  empty token and never puts the token in `argv`. Pinned in Task 2.

---

### Task 1: The VM template and its suite

**Depends on:** none

**Files:**
- Create: `dot_config/ci-runner/lima.yaml`
- Create: `tests/ci-runner.test.sh` (mode 755)
- Modify: `.scripts/test-audit/subjects.tsv` (one row, in path order)
- Modify: `tests/missing-subject.test.sh` (one row, beside the `codex-memory-share` row)

**Interfaces:**
- Produces: the template with exactly one `provision` entry, `mode: system`, whose `script`
  Tasks 2 and 3 extend. In the suite: `yaml_get <ruby-expr>` (prints the value of a Ruby
  expression over the parsed template, bound to `y`), `PROVISION` (path of a temp file holding
  the provision script), `guest_file <guest-path>` (prints the body of the here-document the
  provision script writes to that path; exits 1 if there is none), and the repository's usual
  `is`/`ok`/`no` helpers as in `tests/codex-memory-share.test.sh`.

- [ ] **Step 1: Write the suite with the template assertions**

`tests/ci-runner.test.sh`, bash, header comment naming the subject and S2, guard
`[ -f "$TPL" ] || { echo "missing template under test: $TPL" >&2; exit 2; }`, the helpers above
(parse with `/usr/bin/ruby -ryaml -e`), and these assertions:

```bash
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
```

Final lines print `passed/total` in the form the other prose suites use and exit 1 when
`fail` is non-zero.

- [ ] **Step 2: Run it; expect exit 2**

Run: `./tests/ci-runner.test.sh`
Expected: `missing template under test: …`, exit 2.

- [ ] **Step 3: Write the template**

`dot_config/ci-runner/lima.yaml`: a leading comment (what it is, the spec's name, that
`plain` can only be chosen at creation, and the create command
`limactl create --name=ci ~/.config/ci-runner/lima.yaml`), the Global Constraints values, and

```yaml
images:
  - location: "https://cloud.debian.org/images/cloud/trixie/20261103-2651/debian-13-genericcloud-arm64-20261103-2651.qcow2"
    arch: "aarch64"
    digest: "sha512:5d3ecec46fd29605db4084388a1e2eb82fd19a80202898f962840ea73793261de721e505e3877c829ae86c37fdd2f6c205b0b3b1337a89d0d4b98d9081adc0c2"
```

(the entry of Lima's own `templates/_images/debian-13.yaml`, read 2026-11-21). The provision
script for now is `set -eu`, an
`export DEBIAN_FRONTEND=noninteractive`, and a helper every later step uses:

```sh
# put <mode> <path>: install stdin at <path> only when the content differs
put() { tmp=$(mktemp); cat > "$tmp"; if ! cmp -s "$tmp" "$2"; then install -D -m "$1" "$tmp" "$2"; fi; rm -f "$tmp"; }
```

- [ ] **Step 4: Run it; expect all pass**

Run: `./tests/ci-runner.test.sh`
Expected: 14/14, exit 0.

- [ ] **Step 5: Add the map row and the missing-subject row**

`subjects.tsv`: `dot_config/ci-runner/lima.yaml	data	ci-runner	ci-runner`.
`missing-subject.test.sh`: `missing ci-runner    dot_config/ci-runner/lima.yaml`.
Run: `./tests/run.sh ci-runner missing-subject` — expected both PASS.

- [ ] **Step 6: Commit**

`git add` the four files; message `Add the CI runner VM template and its suite`.

---

### Task 2: Packages, upgrades, concurrency and registration

**Depends on:** Task 1

**Files:**
- Modify: `dot_config/ci-runner/lima.yaml` (provision script)
- Modify: `tests/ci-runner.test.sh`

**Interfaces:**
- Consumes: `put`, `guest_file`, `PROVISION`.
- Produces: guest files `/usr/local/sbin/ci-runner-concurrency` (`ci-runner-concurrency [file]`,
  default `/etc/gitlab-runner/config.toml`) and `/usr/local/sbin/ci-runner-register` (reads the
  token from `${CI_RUNNER_TTY:-/dev/tty}`, config path `${CI_RUNNER_CONFIG:-/etc/gitlab-runner/config.toml}`).
  Task 3 relies on the package names `docker-ce`, `gitlab-runner`, `nftables` being installed
  by this task.

- [ ] **Step 1: Write the failing tests**

Extract each script with `guest_file` into a temp directory, `chmod +x`, and add:

```bash
# concurrency: created when absent, edited in place, runner and token untouched, twice over
f="$ROOT/absent.toml"; "$CONC" "$f"
is "an absent config is created" "$(cat "$f")" 'concurrent = 2'
printf 'concurrent = 1\ncheck_interval = 0\n\n[[runners]]\n  name = "ci"\n  token = "glrt-fixture"\n' > "$ROOT/reg.toml"
"$CONC" "$ROOT/reg.toml"; "$CONC" "$ROOT/reg.toml"
is "concurrent is 2"            "$(grep -c '^concurrent = 2$' "$ROOT/reg.toml")" 1
is "nothing else changed"       "$(grep -v '^concurrent' "$ROOT/reg.toml" | shasum | cut -d' ' -f1)" \
                                "$(printf 'check_interval = 0\n\n[[runners]]\n  name = "ci"\n  token = "glrt-fixture"\n' | shasum | cut -d' ' -f1)"
printf '[[runners]]\n  token = "glrt-fixture"\n' > "$ROOT/noline.toml"; "$CONC" "$ROOT/noline.toml"
is "a missing line is added first" "$(head -1 "$ROOT/noline.toml")" 'concurrent = 2'

# registration: a stub gitlab-runner on PATH records its argv and CI_SERVER_* environment
printf 'glrt-fixture\n' > "$ROOT/tty"; : > "$ROOT/cfg.toml"
PATH="$STUB:$PATH" CI_RUNNER_TTY="$ROOT/tty" CI_RUNNER_CONFIG="$ROOT/cfg.toml" "$REG"; rc=$?
is "register succeeds"            "$rc" 0
is "the token is in the environment" "$(cat "$ROOT/env.token")" glrt-fixture
no "the token is in argv"         grep -q glrt-fixture "$ROOT/argv"
is "the server"                   "$(cat "$ROOT/env.url")" https://gitlab.com
for flag in '--non-interactive' '--executor docker' '--docker-privileged=false' \
  '--docker-pull-policy if-not-present' '--docker-memory 2500m' '--docker-cpus 2' \
  '--docker-service-memory 1g' '--docker-service-cpus 1' '--docker-dns 1.1.1.1' '--docker-dns 9.9.9.9'; do
  ok "register passes $flag" grep -qF -- "$flag" "$ROOT/argv"
done
no "register adds a volume or socket" grep -Eq -- '--docker-volumes|docker\.sock' "$REG"
no "register can lift privileged"     grep -Eq -- 'privileged(=| )true' "$REG"
printf '\n' > "$ROOT/tty"; PATH="$STUB:$PATH" CI_RUNNER_TTY="$ROOT/tty" CI_RUNNER_CONFIG="$ROOT/cfg.toml" "$REG"
is "an empty token is refused" "$?" 1
printf 'glrt-other\n' > "$ROOT/tty"; printf '[[runners]]\n' > "$ROOT/cfg.toml"; : > "$ROOT/argv"
PATH="$STUB:$PATH" CI_RUNNER_TTY="$ROOT/tty" CI_RUNNER_CONFIG="$ROOT/cfg.toml" "$REG"
is "a registered runner is not registered again" "$?" 1
is "and gitlab-runner was not called"            "$(wc -c < "$ROOT/argv" | tr -d ' ')" 0

# apt: the fetch tools come first, then both repositories, and both in unattended upgrades
first_line() { grep -nE "$1" "$PROVISION" | head -1 | cut -d: -f1; }
tools_before_fetch() { [ "$(first_line 'apt-get install .*ca-certificates curl gnupg')" -lt "$(first_line '(curl|gpg) .*(download\.docker\.com|packages\.gitlab\.com)')" ]; }
ok "curl, gpg and certificates are installed before a key is fetched" tools_before_fetch
ok "docker repository"  grep -q 'download.docker.com/linux/debian' "$PROVISION"
ok "runner repository"  grep -q 'packages.gitlab.com/runner/gitlab-runner/debian' "$PROVISION"
u="$(guest_file /etc/apt/apt.conf.d/52unattended-upgrades-local)"
ok "docker upgrades unattended" grep -qF 'origin=Docker' <<<"$u"
ok "runner upgrades unattended" grep -qF 'origin=packages.gitlab.com/runner/gitlab-runner' <<<"$u"
```

- [ ] **Step 2: Run; expect the new assertions to fail** (`guest_file` exits 1: no such file).

- [ ] **Step 3: Extend the provision script**

In order, each step idempotent:
0. Before anything is fetched: `apt-get update` and
   `apt-get install -y ca-certificates curl gnupg` when `dpkg -s` reports one of them missing
   (the cloud image is minimal; the key steps below need all three).
1. `put` the Docker key and source (`/etc/apt/keyrings/docker.asc` from
   `https://download.docker.com/linux/debian/gpg`; `/etc/apt/sources.list.d/docker.sources`
   with `Types: deb`, `URIs: https://download.docker.com/linux/debian`, `Suites: trixie`,
   `Components: stable`, `Architectures: arm64`, `Signed-By: /etc/apt/keyrings/docker.asc`)
   and the runner key and source (`https://packages.gitlab.com/gpgkey/gpg.key` dearmored to
   `/etc/apt/keyrings/runner_gitlab-runner-archive-keyring.gpg`;
   `deb [signed-by=…] https://packages.gitlab.com/runner/gitlab-runner/debian trixie main`).
   Keys are fetched only when the file is absent.
2. `apt-get update` and `apt-get install -y docker-ce docker-ce-cli containerd.io gitlab-runner nftables unattended-upgrades`
   only when `dpkg -s` reports one missing. `nftables.service` is left disabled (its config
   starts with `flush ruleset`, which would wipe Docker's rules on a restart).
3. `put 644 /etc/apt/apt.conf.d/52unattended-upgrades-local` with
   `Unattended-Upgrade::Origins-Pattern` adding
   `"origin=Docker,label=Docker CE,archive=${distro_codename}";` and
   `"origin=packages.gitlab.com/runner/gitlab-runner,codename=${distro_codename}";`, and
   `put 644 /etc/apt/apt.conf.d/20auto-upgrades` enabling the periodic update and upgrade.
4. `put 755 /usr/local/sbin/ci-runner-concurrency`: with the file absent, create it holding
   `concurrent = 2`; with a `^concurrent = ` line, replace that line; otherwise put the line
   first. Writes through a temp file and `cat > file`, so the file's mode and owner stay. Then
   the provision script runs it.
5. `put 755 /usr/local/sbin/ci-runner-register`: refuse (exit 1, a message naming the runner's
   page) when the config has a `[[runners]]` line; print a prompt, read one line from the tty
   path with echo off (`stty -echo` only when it is a terminal), strip whitespace, refuse an
   empty token; `export CI_SERVER_URL=https://gitlab.com CI_SERVER_TOKEN=<token>`; run
   `gitlab-runner register` with the Global Constraints flags and `--docker-image debian:trixie-slim`;
   then `systemctl restart gitlab-runner` when `systemctl` exists.

- [ ] **Step 4: Run; expect all pass.** `./tests/ci-runner.test.sh`, exit 0.

- [ ] **Step 5: Revert check, then commit**

Change `--docker-privileged=false` to `true` in the template, run the suite, see it fail,
restore. Message: `Provision Docker, the runner and its registration script`.

---

### Task 3: Firewall, runner dependency and weekly cleanup

**Depends on:** Task 2

**Files:**
- Modify: `dot_config/ci-runner/lima.yaml` (provision script)
- Modify: `tests/ci-runner.test.sh`

**Interfaces:**
- Consumes: `put`, `guest_file`.
- Produces: guest files `/etc/ci-runner/firewall.nft`, `/usr/local/sbin/ci-runner-firewall`,
  `/etc/systemd/system/ci-runner-firewall.service`,
  `/etc/systemd/system/gitlab-runner.service.d/10-ci-runner.conf`,
  `/usr/local/sbin/ci-runner-cleanup`, `/etc/systemd/system/ci-runner-cleanup.{service,timer}`.

- [ ] **Step 1: Write the failing tests**

```bash
nft_rules="$(guest_file /etc/ci-runner/firewall.nft)"
for r in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
  ok "blocks $r" grep -qF "$r" <<<"$nft_rules"
done
ok "a forward-hook chain of its own"    grep -Eq 'type filter hook forward priority' <<<"$nft_rules"
ok "only out through the uplink"        grep -Eq 'oifname \$uplink ip daddr .* drop' <<<"$nft_rules"
# a predicate, not a pipeline on the helper: a pipeline would run `no` in a subshell and lose its count
unqualified_drop() { grep -E 'drop' <<<"$nft_rules" | grep -vq 'oifname \$uplink'; }
no "a rule without the uplink qualifier" unqualified_drop
no "flushes the whole ruleset"          grep -q 'flush ruleset' <<<"$nft_rules"

# the loader, with stub `ip` and `nft` on PATH
PATH="$STUB:$PATH" IP_DEFAULT='default via 192.168.5.2 dev eth0 proto dhcp' "$FW"
is "the loader passes the uplink to nft" "$(cat "$ROOT/nft.argv")" '-D uplink=eth0 -f /etc/ci-runner/firewall.nft'
PATH="$STUB:$PATH" IP_DEFAULT='' "$FW"
is "no default route: the loader fails" "$?" 1

unit="$(guest_file /etc/systemd/system/ci-runner-firewall.service)"
ok "the firewall unit is a kept oneshot" grep -q '^RemainAfterExit=yes$' <<<"$unit"
ok "it loads before docker"              grep -Eq '^Before=.*docker\.service' <<<"$unit"
dropin="$(guest_file /etc/systemd/system/gitlab-runner.service.d/10-ci-runner.conf)"
ok "the runner requires the firewall"    grep -Eq '^Requires=.*ci-runner-firewall\.service' <<<"$dropin"
ok "and starts after it"                 grep -Eq '^After=.*ci-runner-firewall\.service' <<<"$dropin"
ok "the firewall unit is enabled"        grep -q 'systemctl enable ci-runner-firewall.service' "$PROVISION"

# cleanup, with stub systemctl, docker, reboot and uname recording calls in order
PATH="$STUB:$PATH" DOCKER_VOLUMES='' "$CLEAN"
is "cleanup succeeds" "$?" 0
is "cleanup order" "$(cat "$ROOT/calls")" "$(printf '%s\n' 'systemctl stop gitlab-runner' \
  'docker rm --force c1' 'docker system prune --all --force' 'docker volume prune --all --force' \
  'systemctl start gitlab-runner')"
: > "$ROOT/calls"; PATH="$STUB:$PATH" DOCKER_VOLUMES='runner-cache-1' "$CLEAN"
is "a leftover volume fails the unit"   "$?" 1
ok "and the runner is started again"    grep -qx 'systemctl start gitlab-runner' "$ROOT/calls"
: > "$ROOT/calls"; PATH="$STUB:$PATH" DOCKER_VOLUMES='' KERNEL_PENDING=1 "$CLEAN"
ok "a pending kernel reboots"           grep -qx 'reboot' "$ROOT/calls"
no "instead of starting the runner"     grep -qx 'systemctl start gitlab-runner' "$ROOT/calls"
# every failure keeps its status and still brings the runner back
for failing in 'rm' 'system prune' 'volume prune'; do
  : > "$ROOT/calls"; PATH="$STUB:$PATH" DOCKER_VOLUMES='' DOCKER_FAIL="$failing" "$CLEAN"
  is "a failed docker $failing fails the unit"  "$?" 1
  ok "and the runner is started again ($failing)" grep -qx 'systemctl start gitlab-runner' "$ROOT/calls"
  ok "and the later steps still ran ($failing)"   grep -qx 'docker volume prune --all --force' "$ROOT/calls"
done
: > "$ROOT/calls"; PATH="$STUB:$PATH" DOCKER_VOLUMES='' KERNEL_PENDING=1 REBOOT_FAIL=1 "$CLEAN"
is "a failed reboot fails the unit"     "$?" 1
ok "and the runner is started again"    grep -qx 'systemctl start gitlab-runner' "$ROOT/calls"
timer="$(guest_file /etc/systemd/system/ci-runner-cleanup.timer)"
ok "weekly, at night" grep -Eq '^OnCalendar=Sun \*-\*-\* 04:00' <<<"$timer"
```

The stubs log every call except the two queries: the `docker` stub prints `$DOCKER_VOLUMES` for
`volume ls -q` and `c1` for `ps -aq`, logging neither, and exits 1 (after logging) for the
subcommand named in `$DOCKER_FAIL`; the `reboot` stub exits 1 under `REBOOT_FAIL=1`. The
`uname`/kernel stub: the
cleanup script compares `uname -r` with the newest `/boot/vmlinuz-*` under
`${CI_RUNNER_BOOT:-/boot}`; the test points `CI_RUNNER_BOOT` at a fixture directory and
`KERNEL_PENDING=1` makes the stub `uname` print an older release.

- [ ] **Step 2: Run; expect the new assertions to fail.**

- [ ] **Step 3: Extend the provision script**

1. `put 644 /etc/ci-runner/firewall.nft`: `table inet ci_runner {}`, `delete table inet ci_runner`,
   then the table with one chain `type filter hook forward priority -10; policy accept;` and
   one rule `oifname $uplink ip daddr { the five ranges } drop`.
2. `put 755 /usr/local/sbin/ci-runner-firewall`: take the interface of the default route
   (`ip -o route show default`, field after `dev`); none: message on stderr, exit 1; otherwise
   `exec nft -D uplink=<if> -f /etc/ci-runner/firewall.nft`.
3. `put 644` the unit: `After=network-online.target`, `Wants=network-online.target`,
   `Before=docker.service gitlab-runner.service`, `Type=oneshot`, `RemainAfterExit=yes`,
   `ExecStart=/usr/local/sbin/ci-runner-firewall`,
   `ExecStop=/usr/sbin/nft delete table inet ci_runner`, `WantedBy=multi-user.target`.
4. `put 644` the drop-in: `[Unit]`, `Requires=docker.service ci-runner-firewall.service`,
   `After=docker.service ci-runner-firewall.service`.
5. `put 755 /usr/local/sbin/ci-runner-cleanup`: stop the runner; `docker rm --force` every
   container id from `docker ps -aq` (skipped when there is none); the two prunes;
   `left=$(docker volume ls -q)`; reboot when the newest installed kernel is not the running
   one, else start the runner. **No `set -e`:** the script keeps one status, set to 1 by any
   failing command and by a non-empty `left` (whose names it prints), runs every later step
   regardless, starts the runner on every path that does not reboot, including a `reboot` that
   itself fails, and exits with that status.
6. `put 644` the cleanup service (`Type=oneshot`, `ExecStart=` the script) and timer
   (`OnCalendar=Sun *-*-* 04:00`, `Persistent=false`, `WantedBy=timers.target`).
7. `systemctl daemon-reload`, `systemctl enable ci-runner-firewall.service`,
   `systemctl enable --now ci-runner-cleanup.timer`, `systemctl start ci-runner-firewall.service`,
   and `systemctl restart gitlab-runner` only when the drop-in was just written.

- [ ] **Step 4: Run; expect all pass.**

- [ ] **Step 5: Revert checks, then commit**

Remove `oifname $uplink` from the rule: the suite fails; restore. Remove the `Requires=` line:
it fails; restore. Message: `Gate the runner on its firewall and clean it weekly`.

---

### Task 4: Host wiring and the repository rule

**Depends on:** Task 3

**Files:**
- Modify: `dot_config/homebrew/Brewfile.tmpl`
- Modify: `dot_config/zsh/zshenv`
- Modify: `AGENTS.md`
- Modify: `docs/superpowers/specs/2026-11-21-personal-ci-runner-design.md` (Status line only)

- [ ] **Step 1: Brewfile.** After the `brew "lazysql"` line, in the file's own conditional
style:

```
{{ if eq $live "hercules" -}}
brew "lima"                            # the CI runner's VM (spec 2026-11-21-personal-ci-runner); needs 2.3+ for hostLoopback
{{ end -}}
```

Run: `command chezmoi --source /Users/michael/.local/share/chezmoi-feat-personal-ci-runner cat ~/.config/homebrew/Brewfile | grep -c '"lima"'`
Expected on fenrir: `0`, and the surrounding lines unbroken (`grep -n -B1 -A1 lazysql`).

- [ ] **Step 2: zshenv.** After the Starship block:

```sh
# Lima keeps its instances (the CI runner's VM) out of $HOME; `limactl autostart` records it
export LIMA_HOME="$XDG_DATA_HOME/lima"
```

This takes the spec's S5 condition as met, on evidence read from Lima's source at tag `v2.3.0`
(the version Homebrew ships) on 2026-11-21: `pkg/autostart/managers.go` fills the plist's
`LimaHome` from `dirnames.LimaDir()`, which returns `$LIMA_HOME` when set, and
`pkg/autostart/launchd/io.lima-vm.autostart.INSTANCE.plist` writes it as the agent's
`LIMA_HOME` environment variable. So `limactl autostart enable ci`, run from a shell with this
export, records the directory. Michael's step still checks the written plist (S7 gains that
line in Step 4).

No test: a static export beside the file's other location exports, which have none.
Run: `./tests/run.sh zshenv provision` — expected PASS, totals unchanged.

- [ ] **Step 3: AGENTS.md.** One rule after the Syncthing rule, and `dot_config/ci-runner/` is
not added to Layout (it sits under `dot_config/`):

> - The CI runner on hercules (spec 2026-11-21-personal-ci-runner) lives in a Lima VM built from
>   `dot_config/ci-runner/lima.yaml`; `tests/ci-runner.test.sh` pins its isolation settings.
>   It serves only private GitLab projects that meet the spec's three conditions (private,
>   Michael the only Developer or higher including through groups, fork pipelines in the parent
>   off), and is locked to them. Creating the VM, registering, unlocking or assigning the
>   runner are Michael's; no agent does them, and no job on it runs privileged.

Run: `./tests/run.sh agent-instructions` — expected PASS.

- [ ] **Step 4: Spec status.** `**Status:** In progress (branch `feat/personal-ci-runner`)`.
In S5, replace the `LIMA_HOME` bullet's conditional with the fact and its evidence (Step 2's
two source files at `v2.3.0`): `zshenv` sets it and the autostart agent records it. In S7
step 2, after `limactl autostart enable ci`, add: `plutil -p
~/Library/LaunchAgents/io.lima-vm.autostart.ci.plist` shows `LIMA_HOME` as
`~/.local/share/lima`; if it does not, stop and tell the line.

- [ ] **Step 5: Full run and commit**

Run: `./tests/run.sh --changed` — expected every row PASS or its documented skip.
Message: `Wire the CI runner into the Brewfile, zshenv and the agent rules`.
