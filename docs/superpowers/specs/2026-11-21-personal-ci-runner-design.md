# A self-hosted GitLab CI runner on hercules for private personal projects

**Status:** Abandoned — replaced by a CI runner on Viu More's k1 cluster (spec in opsmaster)
**Date:** 2026-11-21
**Branch:** `feat/personal-ci-runner`
**Sign-off:** Michael, 2026-11-21 (the nine rulings below as written, hercules over the rented
VM included); Codex spec review approved in round 5, after a cold architect read

curato (private, GitLab.com) runs a five-job pipeline on every push and merge request, and the
free tier's 400 compute minutes a month run out fast (Michael's note of 2026-11-20). GitLab counts
only its own instance runners against that quota; a project runner is free. This spec puts one on
hercules (Mac Studio, M1 Max, 32 GB, always on; spec `2026-11-15-hercules-agent-machine`), inside
a dedicated Linux VM, because hercules also holds agent sessions, synced agent memory and
1Password.

## What exists today

- **The pipeline** (curato's `.gitlab-ci.yml`), all Linux containers, no runner tags:

  | Job | Image and services | Runs | Note for an arm64 runner |
  |---|---|---|---|
  | `lint` | `ruby:4.0.9-slim` | every pipeline | multi-arch image |
  | `test` | same, `postgres:18.6` | every pipeline | multi-arch |
  | `cli` | `python:3.13-slim` | every pipeline | multi-arch |
  | `seed_smoke` | ruby, `postgres:18.6` | every pipeline | multi-arch |
  | `a11y` | ruby, postgres, Google Chrome | every pipeline | downloads the **amd64** Chrome `.deb` by name; fails on arm64 as written |
  | `build_image` | `docker:29.9.2-cli` + `docker:29.9.2-dind` | `main` and tags only | needs a **privileged** runner; today builds an amd64 image |

  curato's `Gemfile.lock` already lists `aarch64-linux`.
- **The project:** private, in a group namespace, instance runners on. The agent token cannot
  read members or runners; those checks are Michael's (section 7).
- **hercules:** the Brewfile installs OrbStack on both machines. Nothing was read from or changed
  on hercules for this spec, so what it listens on is unknown until section 7's inventory.
- **GitLab's rules** (docs.gitlab.com, read 2026-11-21): the Docker executor "can be considered
  safe when running in non-privileged mode"; privileged mode means "effectively disabling all the
  container's security mechanisms" and belongs only on isolated VMs; the shell executor runs jobs
  as the runner's user ("only for running trusted builds"). A project runner is created by a
  Maintainer in one project and gets a `glrt-` token shown once; "Lock to current projects" stops
  any other project enabling it; project runners are not enabled for forks. By default a member
  of the parent project may run a fork's merge-request pipeline in the parent. A job with no
  matching runner stays pending and is dropped after an hour; a runner counts as online for about
  two hours after its last contact, so a stopped runner's jobs wait longer.
- **OrbStack's rules** (docs.orbstack.dev): Docker and every machine share one VM and kernel,
  which "isn't a substitute for a full VM against actively malicious code"; the Mac's files are
  shared into that VM and any container can bind-mount `/Users`; containers reach the Mac's
  localhost through `host.docker.internal`, and no setting turns either off for Docker. Ports its
  containers publish are reachable from the LAN by default (`docker.expose_ports_to_lan`).
- **Lima's rules** (lima-vm.io): `plain: true` turns off mounts, port forwarding, the guest agent
  and containerd, and still runs provision scripts, on every boot. With
  `networkOpts.hostLoopback: false` (2.3 or later, vz) the guest cannot reach the Mac's loopback,
  but "a host service listening on all interfaces is still reachable through the host's LAN
  address". The guest's network and DNS (`192.168.5.3`) are a user-space stack inside Lima's host
  agent, a process of Michael's user.

## Goals

- curato's per-push and per-merge-request jobs stop using compute minutes.
- A CI job cannot read Michael's home, the SSH agent, `op`, or services bound to the Mac's
  loopback, and a container escape still does not reach them.
- The runner serves only named private GitLab projects.
- Michael can stop it with one command, and one setting sends every branch's CI back to hosted
  runners.

## Non-goals

- Viu More's k1 runner, and a runner for any project other than his private personal ones.
- A GitHub Actions runner. The dotfiles, tafl and tagteam are public on GitHub and stay on hosted
  runners; nothing here can serve them (section 1).
- Building curato's production image on hercules (ruling 2).
- Autoscaling, ephemeral per-job VMs, a second runner.

## Anti-goals

- The runner process, its token or a job running as Michael on macOS (shell executor, or a runner
  on the host driving a Docker socket).
- CI containers in the same VM or Docker engine as the agents' dev containers and databases.
- A privileged job on this runner.
- A token, project ID or address in this repository.

## Approaches

| Approach | Trade-off | Verdict |
|---|---|---|
| Shell executor on macOS | No VM, but every job is a process of Michael's user with his home, agent socket and `op`; also the pipeline needs Linux images | Rejected: no isolation |
| Runner on macOS driving OrbStack's Docker | Nothing to install; but the runner and its token live in his session, the engine can mount `/Users`, jobs reach the Mac's localhost (dev Postgres, Redis, the Codex daemon), and they share an engine with the agents' containers | Rejected: OrbStack's own docs rule it out for hostile code |
| Runner in an OrbStack *isolated machine* | Nothing to install, no Mac mount, no host network; but it shares OrbStack's one kernel with the VM that holds the Mac file share, so one kernel bug crosses | Rejected: weaker boundary for the same effort |
| **Runner and Docker inside a dedicated Lima VM (Apple Virtualization), no mounts, no agent, no host loopback** | One formula and one template; its own kernel, so a container escape lands in a VM that holds nothing of Michael's; costs 8 GB while it runs; leaves the residual risks of section 4 | **Chosen** |
| A small rented VM (Hetzner CX23 or CAX11, about €6 a month; both listed out of stock on 2026-11-21) | Removes four of section 4's residual risks outright (the LAN, the home address, Lima's host-side stack, a token in his home) and, being isolated, could also run the privileged `build_image`; but a monthly cost, one more machine to patch, and the source on a rented disk | Fallback, and the honest alternative for ruling 1 |

Colima was considered for the VM and dropped: it wraps Lima, mounts the home writable by default,
and exposes neither `plain` mode nor the host-loopback switch directly.

## Design

### 1. Which projects the runner serves, and why no public one

- It is a GitLab **project runner**, created by Michael in curato's settings, with **Lock to
  current projects** on, **Run untagged jobs** off and the tag `hercules`. A GitLab runner takes
  work only from the GitLab projects it is assigned to; GitHub cannot send it anything, and this
  spec installs no Actions runner.
- Not a group runner: the group may hold or later gain other projects, and a group runner would
  serve them all.
- **Whose pipelines run.** The runner is not marked Protected: that would leave every feature
  branch and merge-request pipeline on the shared minutes, which is the cost this removes. The
  guarantee instead rests on the **three conditions** Michael checks at registration
  (section 7):
  1. the project is **Private**;
  2. he is the only person with the Developer role or higher on the project, on every ancestor
     group, and on any group shared into either (roles are inherited), and the project has no
     pipeline trigger tokens or schedules owned by anyone else;
  3. `ci_allow_fork_pipelines_to_run_in_parent_project` is off, so a fork's merge request can
     never run in the parent on this runner. Project runners are not enabled for forks.
- Adding a second personal project is a deliberate act with a written rule (AGENTS.md,
  section 5): check all three conditions on it, unlock, assign, lock again. Before any served
  project stops meeting one of them (made public, a member or group added), its runner
  assignment is removed first.

### 2. The VM

`dot_config/ci-runner/lima.yaml`, a Lima template, deployed to `~/.config/ci-runner/lima.yaml`.
Michael creates the instance `ci` from it.

- `vmType: vz`, arm64, a current Debian or Ubuntu LTS cloud image pinned by digest.
- `cpus: 4`, `memory: 8GiB`, `disk: 60GiB`.
- `plain: true`. `mounts: []` and `ssh.forwardAgent: false` are stated as well, so the file reads
  as what it guarantees.
- `networkOpts.hostLoopback: false`.
- A provision script (system mode). Lima runs it on every boot, so **every step is idempotent**
  and a file is replaced only when its content differs, `config.toml` never. It:
  - installs Docker Engine and `gitlab-runner` from their official apt repositories;
  - enables unattended upgrades with the Docker and GitLab Runner origins added to Debian's
    security origin (by default neither would ever update);
  - sets the global `concurrent = 2` in `/etc/gitlab-runner/config.toml` by a targeted edit of
    that one line (the package creates the file with `concurrent = 1`), never by rewriting the
    file: registration adds the runner and its token there, and a rewrite on boot would drop
    them;
  - installs a native nftables table with its own forward-hook chain (independent of Docker's
    firewall backend and of Docker restarts) that drops packets forwarded **out through the
    VM's uplink interface** to `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`
    and `169.254.0.0/16`, and drops forwarded IPv6 out through the uplink too. A job reaches
    the internet but not the home LAN, NetBird peers, the Mac or Lima's resolver; traffic between
    a job and its services stays on Docker's bridge and is untouched. The table is loaded by its
    own enabled systemd unit at boot; the provision script starts that unit before the runner is
    installed and on every boot, and reloads it in place when its files change; a changed
    firewall that fails to reload stops the runner and the firewall
    unit, whose last valid table stays loaded, so no later start of the runner succeeds until
    the rules load, and provisioning fails.
    A drop-in makes
    `gitlab-runner.service` require that unit and start after it: with the firewall missing or
    failing to load, the runner does not start and takes no job;
  - installs a weekly timer, at a quiet hour, that stops the `gitlab-runner` service, removes
    every remaining container, runs `docker system prune --all --force` and
    `docker volume prune --all --force`, fails loudly (non-zero unit) if any volume is left,
    and reboots the VM when a kernel update is pending, otherwise starts the service again. The
    volume prune is what empties the runner's caches and build directories: they are **named**
    volumes, which `system prune --volumes` leaves alone, and stopping the runner first means
    no job holds one. A job running at that moment fails and is retried by hand; that is the
    price of a real bound. The timer catches up a run missed while the VM was off at the next
    boot (`Persistent`), after provisioning has finished;
  - installs `/usr/local/sbin/ci-runner-register`, which reads the token from the terminal
    without echo and runs `gitlab-runner register --non-interactive` with the pinned settings
    of section 3.
- Autostart through Lima's own launchd support (`limactl autostart enable ci`). hercules stays
  logged in already (hercules spec, section 8 F).

### 3. The runner

Registered by `ci-runner-register` inside the VM. The token goes from GitLab's page to Michael's
terminal to `/etc/gitlab-runner/config.toml` in the VM (root, mode 600). It is never in this
repository, 1Password or a file macOS reads; it does sit inside the VM's disk image, which is a
file in Michael's home on hercules, so that image is excluded from backups (section 7). A rebuilt
VM gets a fresh token from the runner's page.

`[runners.docker]`:

- `privileged = false`, no `volumes` beyond the default `/cache`, no Docker socket.
- `dns = ["1.1.1.1", "9.9.9.9"]`. Without it containers inherit Lima's resolver at
  `192.168.5.3`, which the firewall drops (every lookup would fail) and which jobs should not
  have anyway: it is the Mac's resolver and answers local and VPN names.
- `pull_policy = "if-not-present"`: one project, so GitLab's mixed-trust warning does not apply,
  and Docker Hub's anonymous pull limit is not spent on every job.
- `memory = "2500m"`, `cpus = "2"`, `service_memory = "1g"`, `service_cpus = "1"`. With
  `concurrent = 2` the worst case is two jobs each with one Postgres service: 7 GB in
  containers, 1 GB left for the guest, Docker and the runner. Hosted runners give a job 8 GB, so
  this is a starting point: the acceptance run (section 7) has two service-bearing jobs at once,
  and a job killed for memory there is fixed by sizing, never by lifting a limit.
- Default capabilities stay: the jobs run `apt-get`, `useradd`, `chown` and `runuser`.

### 4. What a malicious dependency can still reach

Stated plainly, by how far it gets:

- **Inside its job (no escape needed):** the checked-out source, the job's CI variables and job
  token, and unrestricted internet egress, so it can exfiltrate the source. That much holds on
  GitLab's hosted runners today. New here: the traffic leaves from **Michael's home address**,
  so anything that allowlists that address trusts the job, and abuse is attributed to his
  connection.
- **Later jobs:** the runner is not ephemeral. A job can leave poisoned content in the cache and
  build-directory volumes that later jobs reuse. GitLab keeps caches of protected and
  unprotected branches apart, which limits a feature-branch job's reach into `main`'s cache only
  if `main` is protected (checked in section 7). `build_image` has `cache: {}` and stays on
  hosted runners (ruling 2), so the production image is never built from these volumes. The
  weekly cleanup runs with the runner stopped and removes every volume, so poisoned content
  lives at most a week; it does not prevent it.
- **After a container escape (a Linux kernel bug, as privileged mode is off):** root in the VM.
  That gives the runner token (it can then take this project's jobs and read their variables)
  and the firewall rules, and with those the home LAN, NetBird peers and **every service
  hercules offers on a non-loopback address**: sshd and Syncthing (key-authenticated), plus
  whatever section 7's inventory finds, such as ports published by OrbStack containers. It does
  not give the Mac's files, the agent socket, `op` or loopback-only services: none is mounted,
  forwarded or routed.
- **After a VM escape:** everything Michael's user has on hercules. The way out is not only an
  Apple Virtualization bug: Lima's host agent runs unsandboxed as Michael and parses every
  packet and DNS query of the guest in its user-space network stack, so a bug there is enough.
  This is the accepted residual risk of running on hercules at all; the rented VM is the answer
  if it is not accepted.
- **Resources:** at most 4 CPUs, 8 GB and 60 GB of disk.

A second, host-side layer is Michael's option, not part of the guarantee: a Little Snitch rule
denying Lima's host agent the local network and `100.64.0.0/10` would hold even against root in
the VM. Whether it also covers hercules' own LAN address is unverified; if he adds it, the probe
in section 7 shows.

### 5. Repository changes (this repository)

- `dot_config/homebrew/Brewfile.tmpl`: `brew "lima"`, hercules only, with a comment naming this
  spec.
- `dot_config/ci-runner/lima.yaml`: section 2.
- `tests/ci-runner.test.sh` (map row in `.scripts/test-audit/subjects.tsv`): pins the safety
  settings of the template so an edit cannot drop one unnoticed: `plain`, no mounts, no agent
  forwarding, host loopback off; in the register command `privileged = false`, no `volumes` or
  socket, the `dns` setting and the four limits; the five firewall ranges together with their
  uplink qualifier; the runner unit's dependency on the firewall unit; that `config.toml` is
  edited, never rewritten.
- `AGENTS.md`: one rule. The runner VM is built from the template; a served project meets the
  three conditions of section 1 and the runner is locked to it; no agent registers, unlocks or
  assigns a runner, or runs a job with privileged mode.
- `LIMA_HOME`: Lima keeps its instances in `~/.lima`, against the strict-XDG rule. `zshenv` sets
  `LIMA_HOME` to `~/.local/share/lima`, and the autostart agent records it: in Lima v2.3.0,
  `pkg/autostart/managers.go` fills the plist's `LimaHome` from `dirnames.LimaDir()`, which
  returns `$LIMA_HOME` when set, and the plist template
  `pkg/autostart/launchd/io.lima-vm.autostart.INSTANCE.plist` writes it as the agent's
  `LIMA_HOME` environment variable.

### 6. Changes in curato (its own merge request, after sign-off)

- `variables: RUNNER_TAG: hercules` and `default: tags: [$RUNNER_TAG]`, so every job goes to the
  runner unless it says otherwise. A **project variable** `RUNNER_TAG` overrides the file for
  every branch at once; that is the off switch.
- `build_image: tags: [saas-linux-small-amd64]`, so it stays on GitLab's hosted amd64 runner.
- `a11y`: download `google-chrome-stable_current_$(dpkg --print-architecture).deb` (Google ships
  an arm64 build since mid-2026), keeping the launch canary. If that build does not start in the
  container, the job takes the hosted tag instead and the spec's saving shrinks by that job.
- The comment block at the top of the file names the runner split.

Instance runners stay enabled on the project, for `build_image` and for the off switch.

### 7. Michael's steps

After both merge requests are open; this repository's merges first.

1. hercules, inventory: `sudo lsof -nP -iTCP -sTCP:LISTEN` and `sudo lsof -nP -iUDP`. Every
   listener not on `127.0.0.1` or `::1` is reachable from an escaped VM. Close what need not be
   open: in OrbStack switch off "Expose ports to LAN" (or quit OrbStack on hercules if nothing
   there uses it), and AirPlay Receiver and Screen Sharing if unused. Keep the list of what
   stays for the probe below; it is not committed.
2. hercules: `chezmoi apply`, `brew bundle install --file ~/.config/homebrew/Brewfile`, then at
   the machine (not over ssh, so launchd sees the GUI session):
   `limactl create --name=ci ~/.config/ci-runner/lima.yaml`, `limactl start ci`,
   `limactl autostart enable ci`; `plutil -p ~/Library/LaunchAgents/io.lima-vm.autostart.ci.plist`
   shows `LIMA_HOME` as `~/.local/share/lima`; if it does not, stop and tell the line. Approve
   Lima in Little Snitch (again after each `brew upgrade lima`). Exclude Lima's instance
   directory from Borg and Time Machine.
3. Run the VM-boundary checks below.
4. GitLab: check the three conditions of section 1. Members of the project, of each ancestor
   group and of groups shared into them; trigger tokens and schedules; visibility Private.
   Switch fork pipelines off, which only the API does:
   `glab api -X PUT projects/<id> -f ci_allow_fork_pipelines_to_run_in_parent_project=false`.
   Confirm `main` is a protected branch.
5. Settings → CI/CD → Runners → Create project runner: tag `hercules`, Run untagged jobs off,
   Lock to current projects on, Protected off, maximum job timeout 1 hour. Copy the token.
6. hercules: `limactl shell ci sudo ci-runner-register`, paste the token. The runner shows
   online in GitLab.
7. Run the container checks and the full pipeline below on a throwaway branch, then merge
   curato's change.

**Acceptance checks.** Two layers, checked separately, because the container firewall would hide
a hole in the VM boundary behind it.

- *The VM boundary, as root in the VM* (`limactl shell ci sudo …`), before the runner is
  registered, again after `limactl stop ci` and `limactl start ci`, and again after a reboot
  issued inside the guest (which must come back by itself; if it does not, the weekly timer
  never reboots and Michael restarts the VM by hand after kernel updates):
  - `findmnt -t virtiofs,9p,fuse.sshfs` prints nothing, and there is no `/Users` or `/Volumes`;
  - `SSH_AUTH_SOCK` is unset and no agent socket exists;
  - with a canary listening on the Mac's loopback (`nc -l 127.0.0.1 <port>` on hercules), a
    connection from the VM to the host gateway on that port fails and the canary receives
    nothing. Root in the VM bypasses the container firewall, so this is what proves
    `hostLoopback`;
  - no port the VM listens on appears on the Mac (`lsof -iTCP -sTCP:LISTEN` on hercules shows
    none of Lima's forwards beyond its own ssh port);
  - after each restart `sudo grep 'Exiting with code' /var/log/cloud-init-output.log | tail -1`
    shows `code 0`, since Lima reports a failed provision nowhere else;
  - after each restart the firewall table is loaded and `gitlab-runner` is active; with the
    firewall unit made to fail by a drop-in provisioning does not repair,
    `/etc/systemd/system/ci-runner-firewall.service.d/fail.conf` holding `[Service]` and
    `ExecStartPre=/bin/false`, and the VM stopped and started (`limactl stop ci`, then
    `limactl start ci`), `gitlab-runner` is not running (inactive), `nft list table inet ci_runner`
    fails and the guest's `/var/log/cloud-init-output.log` shows `Exiting with code 1`; the
    drop-in is then removed, the VM restarted and both are active again;
  - each listener kept in step 1 is probed on hercules' LAN address and the result noted: these
    are the services section 4 says an escape reaches, so each must be one Michael accepts.
- *The container layer, as one temporary job on a branch of curato* (removed before merge):
  `/var/run/docker.sock` does not exist; `CapEff` in `/proc/self/status` is not the full set;
  `/sys/fs/cgroup/cpu.max` and `memory.max` show section 3's limits (`nproc` would not: it
  ignores a CPU quota in these images); a connection to hercules' LAN address on port 22 times
  out; `gitlab.com` resolves and a connection to port 443 succeeds.

A later change to the template does not reach the running VM by itself: `limactl create` copies
it into the instance as `$LIMA_HOME/ci/lima.yaml`, and each start provisions from that copy.
After `chezmoi apply`, `limactl stop ci`, copy `~/.config/ci-runner/lima.yaml` over that file,
`limactl start ci`, then rerun the VM-boundary checks above; the disk, and so the registration,
survive. `plain`, `vmType`, `images` and the architecture are fixed when the instance is
created, so they cannot change this way (a bumped image digest does not reach the existing disk);
a rebuilt VM picks them up.

Then one full pipeline: `lint`, `test`, `cli`, `seed_smoke` and `a11y` pass on the runner, with
`test` and `seed_smoke` running at the same time (which also shows `concurrent = 2` took), and
`build_image` runs on a hosted runner. Then a second pipeline on the same branch: the runner
keeps its build directory, and `test` and `cli` hand the checkout to another user, so only a
second run shows that the next job's fetch still works there. If a
VM-boundary check fails and cannot be fixed in the template, the runner is removed and the
fallback applies.

## Cost on hercules

- **Memory:** 8 GB of 32 while the VM runs; treat it as held, since a VM returns little once it
  has used it. 24 GB remain for agent lines and the Mac.
- **CPU:** up to 4 of 10 cores during a pipeline, about none idle. A pipeline has four jobs in
  its first two stages; at two at a time it takes longer than on hosted runners' parallel fleet.
- **Disk:** up to 60 GB, sparse.
- **Compute minutes:** only `build_image` (on `main` and tags) still counts.

## Turning it off

- For a while: `limactl stop ci`. Jobs tagged `hercules` then wait, and are dropped about an hour
  after GitLab stops counting the runner as online (roughly two to three hours in all);
  `limactl start ci` brings it back.
- With CI still running: set the project variable `RUNNER_TAG` to `saas-linux-small-amd64`,
  created **unprotected** (a protected variable reaches only pipelines on protected branches
  and tags, so it would move `main` alone). Every branch's next pipeline goes to hosted
  runners, with no commit; delete the variable to come back.
- For good: set that variable, delete the runner in curato's settings (this revokes the token),
  `limactl autostart disable ci`, `limactl delete ci`, drop the Brewfile line, and remove the
  tag lines from curato.

## Rulings confirmed at sign-off

1. A dedicated Lima VM on hercules, not OrbStack and not a rented VM. The rented VM costs about
   €6 a month and removes four residual risks (section 4: the LAN and hercules' own listeners,
   the home address, Lima's host-side stack, the token in his home); hercules costs nothing and
   needs the inventory of step 1.
2. `build_image` stays on GitLab's hosted runners: it needs privileged mode, which this runner
   refuses, and an amd64 image, which hercules would have to emulate. It keeps spending minutes
   on each `main` push and tag. If that alone exhausts the quota, the next step is a separate
   decision (a rootless builder, or the rented amd64 VM), not a privileged flag here.
3. The runner is locked and private-only but not Protected; the guarantee is the three
   conditions of section 1.
4. Routing by a tag held in `RUNNER_TAG`, with instance runners left on.
5. 4 CPUs, 8 GB, two concurrent jobs, 2.5 GB a job and 1 GB a service.
6. The token lives only in the VM; no 1Password item.
7. Container egress to private ranges is blocked in the VM, and jobs resolve names through
   Cloudflare and Quad9 rather than the Mac's resolver; the Little Snitch rule is optional.
8. A weekly cleanup that stops the runner and may fail a job running at that hour.
9. One static test suite pinning the template's safety settings; the isolation itself is proven
   by the acceptance checks, live.

## Left to the builder

- The image and its digest; the exact apt setup for Docker and `gitlab-runner`; the unattended
  upgrades origins.
- Confirming against the installed Lima: that Homebrew ships 2.3 or later, the `hostLoopback`
  key's exact spelling, the `autostart` syntax, and whether the autostart agent honours
  `LIMA_HOME`. If host loopback cannot be switched off, stop and bring it to Michael.
- The uplink interface's name in the firewall table, and the timer's day and hour (a quiet one);
  a weekly re-pull of the images is accepted.
