# Writing and changing suites

What binds only while a file under `tests/` is written or changed. Running suites, the runner's
knobs, the gated suites and reporting: the root `AGENTS.md`, Testing.

## A new suite

A suite whose subject has moved must fail loudly, not silently pass: each one checks its
target exists and exits 2 if not. Keep that when adding suites — a guard test whose guard
is missing otherwise reports every "must allow" case as a pass. Exit 2, never 1: 1 means an
assertion failed. `run.sh` prints the guard's line under the suite's `????` row.
`tests/missing-subject.test.sh` hides one file per row and pins the exit; a
suite whose guard changes gets a row there.

Two output idioms exist and `run.sh` counts both: prose (`  ok  …` / `  PASS: …`) and the
`KEY=VALUE` status the `live-agent-auth`, `live-agent-signing`, `live-credential-boundary` and
`live-write-boundary` suites share (the first three also so they never print key material). A kv
suite encodes failures in its values and exits with the count, so it is judged on exit status
alone — the prose cross-check does not apply to it. A kv suite that fails a probe closes with one
`failed_keys=<key>,<key>` line (not when it dies early, before any key); `run.sh` shows that line
and any `INCONCLUSIVE:` lines under the FAIL row, never a `KEY=VALUE` line, so no value is
echoed, and does not count it as an assertion. A new kv suite should print it.
`tests/write-boundary-probe.test.sh` drives `live-write-boundary` against a throwaway `HOME`
and a stubbed `mkdir`, so its `.git/modules` probe, its sibling probe (including the
INCONCLUSIVE-only exit 2, through the `WRITE_BOUNDARY_SIBLING_ONLY` seam, refused against the
real home) and `failed_keys` line are tested without measuring a sandbox.

## Suite-specific

Running a zsh suite under `bash` reports bogus syntax errors that read exactly like a
regression, because it stubs zsh builtins. `./tests/x.test.sh` is always right;
`bash tests/x.test.sh` is the footgun. `run.sh` executes them for this reason.

Two suite-specific gotchas worth keeping: `codex-config` drives the `modify_` **template**
via `chezmoi execute-template --with-stdin --file` — without `--with-stdin` every case dies
on "map has no entry for key stdin", and its empty-input fixture is `''`, not `'{}'`,
because that file is TOML. `herdr-phase` stubs `herdr`, `glab` and `gh` on `PATH`; the script it
tests is not runnable sandboxed, since it cannot create its run lock in `~/.cache` and exits 2.
The script itself needs `/usr/bin/jq` and `/usr/bin/timeout` (and
`/usr/bin/lockf`); the stubs do not replace them, and `refresh` exits 2 when any of them is
missing.

`xreview-guard-cli` (its exit 2: the root `AGENTS.md`, Testing): the pin in the suite is updated
in the change that weighs the new command or flag (gate it, deny it or leave it).

## History

Comparing a sandboxed run against an unsandboxed one once produced a believable "18-test
regression" that was entirely an artefact.

`bash tests/live-{a,b}.test.sh` expands to `bash a b` — only the first runs, the second becomes
an ignored `$1`, and the skipped suite prints nothing, so the run looks like a clean pass.

`run.sh` judges each suite on its exit status and cross-checks that against the counted
assertions: a suite that dies partway prints only the assertions it reached and would otherwise
look clean, so it is reported `INCONSISTENT` instead of folded into a total.

A handoff once claimed "324 assertions green" when it was 321 green / 3 red — 324 was the
*total*.

**Inside a Herdr pane, `HERDR_SESSION` does not pick the session.** herdr 0.9.3 reads
`HERDR_SESSION`, but `HERDR_SOCKET_PATH`, which herdr exports into every pane, outranks it;
only `--session` outranks the socket (measured 2026-09-30 with `herdr status`). So
`layout.sh`, `tab-goto.sh` and `phase.sh` thread `--session` in themselves, and nothing in
them may call `command herdr` bare — from inside a pane a bare call targets the pane's own
session, whatever `HERDR_SESSION` says. That is what made `dev-topology`'s isolation a
fiction: it built its fixtures into the live session and then asserted against an empty
`dev-test`. `layout.sh` also starts a server whenever `HERDR_SESSION` is set, even inside a
Herdr pane, because the pane you are in belongs to a different session than the one you
named.
