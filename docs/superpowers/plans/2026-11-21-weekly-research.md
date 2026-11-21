# Weekly research: implementation plan

> **For agentic workers:** run this with the `plan-run` skill (it overrides
> superpowers:subagent-driven-development). Steps use checkbox (`- [ ]`) syntax.

**Status:** Implemented (completed 2026-11-21, branch `feat/weekly-research`, its PR against `main`; do not run it again — its execution notes bind that run only).
**Goal:** a weekly launchd job that checks a fixed source list with `claude -p`, holding only the
two web tools behind a kernel-enforced fetch proxy, and writes one dated note.
**Architecture:** `weekly-research` (bash) builds the prompt, starts `weekly-research-proxy`
(system Python), runs `claude` under `sandbox-exec` with an allowlisted environment, checks the
run's JSON stream, and owns the note, the state file and the vault copy. The model returns text
only.
**Tech stack:** bash 3.2, `/usr/bin/python3` (standard library), `jq`, `sandbox-exec`, launchd,
chezmoi templates, `tests/run.sh`.
**Spec:** `docs/superpowers/specs/2026-11-21-weekly-research-design.md` (read it first; the plan
argues from it). Before touching `tests/`, read `tests/AGENTS.md`.

`CO` is the checkout, `/Users/michael/.local/share/chezmoi-feat-weekly-research`. Every task
runs there, on branch `feat/weekly-research`; check `git branch --show-current` before each
commit.

## Global constraints

- The repository is public: no private text in any file. The source list holds ids, kinds and
  URLs only.
- No task loads the LaunchAgent, runs `chezmoi apply`, or writes under `~/.config`, `~/.local`,
  `~/Library` or the real vault. Suites use a scratch `HOME` and the `WEEKLY_RESEARCH_*`
  overrides below.
- The wrapper is bash 3.2 compatible, mode 755, and pins
  `PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin` (`WEEKLY_RESEARCH_PATH` replaces it).
- The proxy's shebang is `#!/usr/bin/python3`, standard library only.
- Caps, verbatim from the spec: 40 rows; four proposals in the body; one upkeep entry of at
  most ten ids; `--max-budget-usd 5`; 30 minutes wall clock; a body of at most 200 lines; quiet
  after 26 weeks (182 days); broken at four failed fetches in a row; a run fails when fewer than
  half the rows have an item in "Seen"; a vault failure note at the second failure in a row;
  the last eight logs are kept.
- Overrides the wrapper honours (tests and the live suite only; launchd sets none):
  `WEEKLY_RESEARCH_CONFIG` (default `~/.config/weekly-research`), `WEEKLY_RESEARCH_STATE`
  (default `${XDG_STATE_HOME:-~/.local/state}/weekly-research`), `WEEKLY_RESEARCH_INBOX`
  (default `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/MSB/1. Inbox`),
  `WEEKLY_RESEARCH_TODAY` (`YYYY-MM-DD`), `WEEKLY_RESEARCH_TIMEOUT` (seconds, default 1800),
  `WEEKLY_RESEARCH_MODEL` (default `opus`), `WEEKLY_RESEARCH_BUDGET` (default `5`),
  `WEEKLY_RESEARCH_PATH`.
- The wrapper starts the proxy that sits beside it (`$(dirname "$0")/weekly-research-proxy`)
  and reads `network.sb`, `prompt.md` and `sources.tsv` from the config folder. Every suite
  stages the checkout's files under their deployed names: both scripts copied into a scratch
  `bin/`, `dot_config/weekly-research/*` into a scratch config folder. No suite reads a
  deployed copy.
- Commits: small, imperative mood, no attribution lines.

## Review focus

1. A "Seen" title containing `|`, a tab or a control character: the state file stays one row
   per source with seven fields (Task 4 tests it).
2. A model body that carries a heading named like a wrapper section, or a leading `---`: it
   stays below the "Research (model output)" heading, after everything the wrapper wrote
   (Task 3; see the spec's "The note").
3. A second run on the same day: the state note is replaced, an existing vault note is never
   overwritten (Task 4).
4. The proxy gets a host with several addresses, one private: refused (Task 1).
5. `claude` is missing, or exits before any `system/init` line: a failed run with a reason, no
   hang and no stray proxy process (Task 3).

---

### Task 1: The fetch proxy

**Depends on:** none

**Files:**
- Create: `dot_local/bin/executable_weekly-research-proxy` (755)
- Create: `tests/weekly-research-proxy.test.sh` (bash, 755)
- Modify: `.scripts/test-audit/subjects.tsv`, `tests/missing-subject.test.sh`

**Interfaces:**
- Produces: `weekly-research-proxy --port-file <path> --log <path>`: binds `127.0.0.1` on a
  free port, writes the port number to `<path>` once listening, serves until TERM. It handles
  `CONNECT host:port` and absolute-URI plain HTTP requests. One log line per request:
  `<ISO time>\t<allow|deny>\t<host>:<port>\t<reason or address>`.
- Produces: `weekly-research-proxy --check <host> <port>`: prints `allow <address>` and exits 0,
  or `deny <reason>` and exits 1. It runs the same function the server uses:
  `check(host, port)`, returning `(True, address)` or `(False, reason)` and calling
  `socket.getaddrinfo` exactly once. The file runs its command line only under
  `if __name__ == "__main__":`, so a test can load it as a module.
- The rule: resolve with `getaddrinfo`; deny when the port is not 80 or 443, when resolution
  fails, or when **any** returned address is loopback, private, link-local, carrier-grade NAT
  (`100.64.0.0/10`), multicast, unspecified, reserved, or an IPv4-mapped IPv6 form of one; on
  allow, connect to the first address it checked, never resolve again.

- [ ] **Step 1: Write the failing suite.** `--check` rows, each asserting the exit status and
  the first word: deny `127.0.0.1 443`, `10.0.0.1 443`, `172.16.0.1 443`, `192.168.1.1 443`,
  `169.254.169.254 80`, `100.64.0.1 443`, `0.0.0.0 443`, `224.0.0.1 443`, `::1 443`,
  `fe80::1 443`, `fc00::1 443`, `::ffff:127.0.0.1 443`, `localhost 443` (a name resolving to
  loopback), `93.184.216.34 8080` (port), `no-such-host.invalid 443`; allow `93.184.216.34 443`
  and `2606:2800:220:1:248:1893:25c8:1946 443`. Mixed-address rows: a `/usr/bin/python3` snippet in the
  suite loads the script with `importlib.machinery.SourceFileLoader`, replaces
  `socket.getaddrinfo` with a fake, and asserts `check("x.example", 443)` denies for the
  answers `[93.184.216.34, 10.0.0.1]` and `[10.0.0.1, 93.184.216.34]`, allows
  `[93.184.216.34, 93.184.216.35]` with the first address, and that the fake was called once.
  Server rows: start it, read the port file,
  `curl -x` a `CONNECT` to `localhost:443` and a plain `http://127.0.0.1/` both answer 403 and
  each adds a `deny` log line; TERM ends the process. Guard: exit 2 when the script is missing.
- [ ] **Step 2: Run it:** `./tests/weekly-research-proxy.test.sh`. Expected: exit 2, missing
  subject.
- [ ] **Step 3: Implement the proxy** with `ipaddress`, `socket`, `socketserver` and `select`.
  A refused request gets `403` and the connection closes; an allowed `CONNECT` gets `200` and a
  byte relay; an allowed plain request is forwarded with `Connection: close`.
- [ ] **Step 4: Run it.** Expected: every row passes, exit 0.
- [ ] **Step 5: Add the map row and the missing-subject row** for the proxy, then run
  `./tests/run.sh weekly-research-proxy missing-subject`. Expected: both pass.
- [ ] **Step 6: Commit:** "Add the weekly research fetch proxy".

### Task 2: Prove the isolated start, and record its init event

**Depends on:** Task 1 (the proxy)

This is the spec's stop condition, checked before the wrapper is built. It spends two haiku
calls (under $0.10) and must run **unsandboxed**: `sandbox-exec` cannot start inside the
sandbox. A subagent that cannot run unsandboxed reports that and stops; the controller runs the
steps.

**Files:**
- Create: `dot_config/weekly-research/network.sb`
- Create: `tests/fixtures/weekly-research/init.json`

**Interfaces:**
- Produces: `network.sb`, used as `sandbox-exec -D PROXY_PORT=<port> -f network.sb <command>`:
  allow everything, deny `network-outbound`, then allow outbound to `localhost:<PROXY_PORT>`
  and to local Unix sockets.
- Produces: the `claude` argument list, fixed here for Task 3:
  `claude -p --restricted --tools WebFetch,WebSearch --strict-mcp-config
  --disable-slash-commands --no-session-persistence --settings
  '{"permissions":{"allow":["WebFetch","WebSearch"]}}' --permission-mode dontAsk --model <model>
  --max-budget-usd <budget> --output-format stream-json --verbose`, the prompt on stdin, started
  as `env -i HOME=… USER=… PATH=… TMPDIR=… LANG=… HTTPS_PROXY=http://127.0.0.1:<port>
  HTTP_PROXY=http://127.0.0.1:<port> sandbox-exec …` from an empty directory.
- Produces: `init.json`, the real `system/init` event of that start with `session_id`, `cwd`
  and any path under the home directory replaced by placeholders. Task 3's init check and its
  stub are built from this file's field names.

- [ ] **Step 1: Write `network.sb`.**
- [ ] **Step 2: Check the profile alone.** With the checkout's proxy running and the checkout's
  `network.sb`: under the profile,
  `curl --noproxy '*' -m 5 https://1.1.1.1` fails, `curl --noproxy '*' -m 5 http://192.168.1.1`
  fails at once (not a timeout), a connection to another loopback listener fails, and
  `curl -x http://127.0.0.1:<port> https://example.com` succeeds.
- [ ] **Step 3: Run `claude` with the argument list above,** model `haiku`, budget `0.2`,
  prompt "Fetch https://example.com with WebFetch and give its title. Then fetch
  http://localtest.me/ and report the error." Expected: `system/init` shows
  `apiKeySource: "none"`, tools exactly `WebFetch` and `WebSearch`, no MCP server; the result is
  a success; the proxy log has an `allow` for `example.com:443` and a `deny` for `localtest.me`.
- [ ] **Step 4: Decide from the result.**
  - The login fails under the profile, or the proxy log shows no line for the fetches (they
    bypassed it and failed in the kernel, or worked): **stop the plan** and report. This is the
    spec's fallback condition and goes to Michael.
  - The init event lists agents, skills or plugins that are not empty under these flags: stop
    and report which; the spec's init check says they are empty, so it needs a ruling.
- [ ] **Step 5: Save the scrubbed init event** as the fixture, and commit: "Add the weekly
  research network profile and the init fixture". Put the measured facts (CLI version, cost of
  the two calls, the proxy log lines) in the commit body.

### Task 3: The wrapper's run

**Depends on:** Task 1 (proxy interface), Task 2 (argument list, `network.sb`, `init.json`)

**Files:**
- Create: `dot_local/bin/executable_weekly-research` (755)
- Create: `dot_config/weekly-research/prompt.md`, `dot_config/weekly-research/sources.tsv`
- Create: `tests/weekly-research.test.sh` (bash, 755)
- Modify: `.scripts/test-audit/subjects.tsv`, `tests/missing-subject.test.sh`

**Interfaces:**
- Consumes: the proxy and the argument list of Tasks 1 and 2.
- Produces: `sources.tsv`: `#` comment lines, then `id<TAB>kind<TAB>url`; ids match
  `[a-z0-9-]+`; kinds are `official`, `vendor`, `independent`, `practitioner`.
- Produces: `prompt.md`: front matter with one `spec: <file name>` line per workflow spec (today
  `2026-11-20-workflow-v2-design.md`), then the instructions of the spec's "What the prompt asks
  for" and the note's body shape. The body the model returns starts at `## Proposals` and holds,
  in order: `## Proposals`, `## Evidence on settled questions`, `## New this week, no change
  proposed`, `## Pages that addressed the agent`, `## Seen`. A proposal is a `### ` heading.
  A "Seen" row is `| <id> | <YYYY-MM-DD or -> | <title or fetch failed> |`. A row is
  **fetched** when its title is not `fetch failed`; its date is `-` when the page carries none.
- Produces, in the state folder: `notes/<date>.md`, `failures/<date>.txt`, `logs/<date>.jsonl`,
  `logs/<date>.proxy.log`, `last-run` (lines `key=value`: `date`, `result=ok|failed`, `reason`,
  `cost`, `note`, `vault=writable|not writable`, `failures_in_row`), and a lock directory.
- Produces: shell functions Task 4 fills or calls: `fail_run <reason>` (writes the failure
  record and `last-run`, never a note, exits 1) and `finish_run <body-file> <cost>`.

The prompt the wrapper sends is, in order: `prompt.md` without its front matter; a section
"Sources" with one line per row (`id`, kind, URL, last checked, newest item); a section
"Current workflow" with `~/.config/agents/GLOBAL.md` and each named spec from
`~/.local/share/chezmoi/docs/superpowers/specs/`, each inside a fence that names it as data; a
line naming each missing file.

The seed of `sources.tsv` (36 rows; the wrapper and the suite hold no row by name):

| id | kind | url |
|---|---|---|
| claude-code-releases | official | https://github.com/anthropics/claude-code/releases.atom |
| claude-code-changelog | official | https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md |
| claude-code-whats-new | official | https://code.claude.com/docs/en/whats-new/index.md |
| claude-code-best-practices | official | https://code.claude.com/docs/en/best-practices |
| claude-code-sub-agents | official | https://code.claude.com/docs/en/sub-agents |
| claude-code-workflows | official | https://code.claude.com/docs/en/workflows |
| claude-code-code-review | official | https://code.claude.com/docs/en/code-review |
| claude-code-routines | official | https://code.claude.com/docs/en/routines |
| claude-code-advisories | official | https://github.com/anthropics/claude-code/security/advisories |
| anthropic-engineering | official | https://www.anthropic.com/engineering |
| claude-blog | official | https://claude.com/blog |
| codex-releases | official | https://github.com/openai/codex/releases.atom |
| codex-changelog | official | https://learn.chatgpt.com/docs/changelog |
| superpowers-releases | official | https://github.com/obra/superpowers/releases.atom |
| mcp-spec-releases | official | https://github.com/modelcontextprotocol/modelcontextprotocol/releases.atom |
| openai-dev-blog-codex | vendor | https://developers.openai.com/blog/topic/codex |
| cognition-blog | vendor | https://cognition.com/blog |
| cursor-blog | vendor | https://cursor.com/blog |
| amp-notes | vendor | https://ampcode.com/notes.rss |
| github-blog-copilot | vendor | https://github.blog/ai-and-ml/github-copilot/ |
| metr | independent | https://metr.org/feed.xml |
| dora | independent | https://dora.dev/research/ |
| arxiv-cs-se | independent | https://rss.arxiv.org/rss/cs.SE |
| thoughtworks-radar | independent | https://www.thoughtworks.com/radar |
| epoch-ai | independent | https://epoch.ai/latest |
| owasp-genai | independent | https://genai.owasp.org/feed/ |
| embrace-the-red | practitioner | https://embracethered.com/blog/index.xml |
| willison-agentic-engineering | practitioner | https://simonwillison.net/tags/agentic-engineering.atom |
| willison-lethal-trifecta | practitioner | https://simonwillison.net/tags/lethal-trifecta.atom |
| fowler-exploring-gen-ai | practitioner | https://martinfowler.com/articles/exploring-gen-ai.html |
| ronacher | practitioner | https://lucumr.pocoo.org/feed.atom |
| jesse-vincent | practitioner | https://blog.fsck.com/feed/feed.xml |
| humanlayer | practitioner | https://www.humanlayer.dev/blog |
| pragmatic-engineer | practitioner | https://newsletter.pragmaticengineer.com/feed |
| hashimoto | practitioner | https://mitchellh.com/writing |
| huntley | practitioner | https://ghuntley.com/rss/ |

The pinned skills' releases are left out: the `skill-updates` workflow already reports them.

- [ ] **Step 1: Write the failing suite.** `claude`, `sandbox-exec` and `osascript` are stubs on
  a `WEEKLY_RESEARCH_PATH`; the `sandbox-exec` stub records its arguments and runs the rest;
  the `claude` stub records argv, environment (`env`), working directory and stdin, then prints
  an init line built from `tests/fixtures/weekly-research/init.json` and a result line from a
  case file. `HOME` is a scratch directory with a config folder, a `GLOBAL.md`, a spec and an
  inbox. Cases:
  - the list: the real `sources.tsv` has at most 40 rows, the row format, unique ids, known
    kinds; a scratch list with 41 rows, a duplicate id or an unknown kind is a failed run;
  - argv equals Task 2's list with `opus` and `5`; `sandbox-exec` got `-D PROXY_PORT=<the port
    file's number>` and the config folder's `network.sb`; the working directory is empty and under the
    state folder;
  - environment: with `GH_TOKEN`, `GITLAB_TOKEN`, `ANTHROPIC_API_KEY`, `SSH_AUTH_SOCK` and
    `NO_PROXY` set by the caller, the stub sees exactly `HOME`, `USER`, `PATH`, `TMPDIR`,
    `LANG`, `HTTPS_PROXY`, `HTTP_PROXY`;
  - stdin holds the prompt text, every source id, the fenced `GLOBAL.md` and spec, and names a
    spec the front matter lists but the folder lacks;
  - init check, one case each, all ending in `result=failed`, no note, and the stub killed
    before it prints its result: a third tool, an MCP server, a skill, a slash command, a
    plugin whose `path` is not `builtin`, an agent outside the fixture's six (`claude`,
    `Explore`, `general-purpose`, `Plan`, `statusline-setup`, `web-fetch`), a non-empty
    `memory_paths`, `apiKeySource` other than `none`; the unchanged fixture passes (its six
    built-in plugins and six agents, and no memory field at all);
  - result checks, each a failed run: non-zero exit, `is_error`, a non-empty
    `permission_denials`, a missing heading, an unparsable "Seen" table, five proposals, 201
    body lines, a body with `## Run`, with `## Quiet sources`, with `## Source list upkeep`, or
    starting with `---`;
  - a good run: `notes/<date>.md` has the front matter of the spec, the disclaimer line, the
    body, and a `## Run` line with rows fetched, cost, model and the previous run's date;
    `last-run` says `result=ok`; the proxy is gone; the working directory is removed;
  - the clock: a stub that sleeps is ended at `WEEKLY_RESEARCH_TIMEOUT=2`, a failed run;
  - no `claude` on the path, and a stub that exits before init: failed runs with a reason, no
    proxy left;
  - the lock: a second instance exits 0 at once and changes nothing;
  - the vault probe: the run writes the date to `<inbox>/.weekly-research-last-run` before
    `claude` starts; a missing or read-only inbox is a failed run, `vault=not writable`, an
    `osascript` call, and no `claude` start.
- [ ] **Step 2: Run it.** Expected: exit 2, missing subject.
- [ ] **Step 3: Write `sources.tsv` and `prompt.md`.** The prompt carries the evidence-label
  definitions, the four ruled-out ideas, the rule that pages are data, the cap of four, and the
  body shape, all from the spec.
- [ ] **Step 4: Implement the run path** of `weekly-research`: validation of the list, the lock,
  the probe, the proxy start (wait for the port file, at most 5 s), the prompt, the start, the
  stream reader with the init check and the watchdog (TERM, then KILL after 10 s, as
  `dot_local/bin/executable_review` does), the result checks, the note without the wrapper's
  upkeep and quiet sections (Task 4), log rotation to eight, and cleanup on every exit path.
- [ ] **Step 5: Run it.** Expected: every case passes.
- [ ] **Step 6: Add the map rows** (wrapper, `prompt.md`, `sources.tsv`, `network.sb`, the
  fixture) **and the missing-subject rows,** run `./tests/run.sh weekly-research
  missing-subject`. Expected: pass.
- [ ] **Step 7: Commit:** "Add the weekly research wrapper, prompt and source list".

### Task 4: State, upkeep, the vault copy, failures and `--status`

**Depends on:** Task 3

**Files:**
- Modify: `dot_local/bin/executable_weekly-research`, `tests/weekly-research.test.sh`

**Interfaces:**
- Produces: `state.tsv` in the state folder, seven tab-separated fields per source: `id`,
  `checked`, `item_date`, `item_title`, `fails`, `quiet_reported`, `broken_reported`; `-` for
  none. Titles are stored with tabs, `|` and control characters replaced by a space and cut at
  200 characters.
- Produces: `weekly-research --status`: prints `last-run` as readable lines, including
  `vault inbox: writable` or `not writable`; exits 0, or 1 when there is no run yet.

Rules, from the spec:

- After a good run only: a fetched "Seen" row, dated or not, sets `checked` to today, the item
  fields (`item_date` is `-` for an undated page), and `fails` to 0 with `broken_reported`
  cleared; a `fetch failed` row or a listed id missing from
  "Seen" adds one to `fails` and keeps the rest; an id not in the list is ignored; a state row
  whose id left the list is dropped. A failed run changes nothing.
- The fetch floor: when the fetched rows, times two, are fewer than the list's rows, the run
  fails.
- Quiet: `item_date` is a date more than 182 days before today; a row without a date is never
  quiet. A row whose item is newer has `quiet_reported` cleared.
- Broken: `fails` is 4 or more.
- Upkeep: the rows quiet or broken with their `*_reported` field empty, in list order, the
  first ten. If there are any, the note gets `## Source list upkeep` with one line, `Propose
  removing or repairing: <ids>` (each id followed by `(quiet)` or `(broken)`), and those rows
  get today's date in the matching field.
- Between the front matter and the `## Research (model output)` heading the note has
  `## Source list upkeep` (when present) and `## Quiet sources` (every quiet id with its item
  date, or `none`); the run's facts are front matter (Task 3).
- The vault copy: when the body has at least one proposal or the note has an upkeep entry,
  copy the note to `<inbox>/<date>-weekly-research.md` unless that file exists.
- Failures: `failures_in_row` counts failed runs since the last good one. When it reaches
  exactly 2, write `<inbox>/<date>-weekly-research-failed.md` (the vault's front matter, the
  reason, the log path) unless that file exists, which is left as it is. When the inbox is not
  writable, every such run calls `osascript` instead.

- [ ] **Step 1: Add the failing cases:**
  - state: a fetched row moves, a fetched row with the date `-` moves too and stores `-`, a
    `fetch failed` row and an omitted row do not and count a
    failure, an unknown id is ignored, a delisted row is dropped, a failed run leaves
    `state.tsv` byte-identical;
  - a title with `|`, a tab and an escape character leaves seven fields and one line;
  - the floor: 4 of 10 fetched fails, 5 of 10 passes, and 5 undated fetched rows of 10 pass;
  - an undated row is never quiet;
  - quiet at 183 days and not at 182; reported once; cleared by a newer item;
  - broken: three failures do nothing, the fourth raises it, a fetch resets it, it is reported
    once;
  - upkeep: twelve newly quiet rows give one line with ten ids, the next run the other two,
    the third run none;
  - the vault copy: none without a proposal or an upkeep entry, one with either, an existing
    file is left byte-identical, a second run on the same day replaces the state note;
  - failures: the first writes no vault note, the second one, the third none, a good run
    resets the count; two failures, a good run and two more failures on one day leave the
    first failure note byte-identical; with an unwritable inbox each failure calls `osascript`;
  - `--status` after a good run, after a failed one, and before any.
- [ ] **Step 2: Run the suite.** Expected: the new cases fail, the Task 3 cases pass.
- [ ] **Step 3: Implement** the state update, the upkeep and quiet sections, the copy, the
  failure note and `--status`.
- [ ] **Step 4: Run it.** Expected: every case passes.
- [ ] **Step 5: Commit:** "Track sources, report upkeep and failures in weekly research".

### Task 5: The schedule and the documentation

**Depends on:** Task 3 (the wrapper's path and name)

**Files:**
- Create: `Library/LaunchAgents/be.netronix.weekly-research.plist.tmpl`
- Modify: `.chezmoidata/machines.toml` (add `research_host = "fenrir"` with a comment),
  `.chezmoiignore` (ignore the plist unless `.chezmoi.hostname` equals `.research_host`),
  `AGENTS.md`, `tests/weekly-research.test.sh`, `.scripts/test-audit/subjects.tsv`

**Interfaces:**
- Produces: label `be.netronix.weekly-research`; `ProgramArguments` is
  `{{ .chezmoi.homeDir }}/.local/bin/weekly-research`; `StartCalendarInterval` Weekday 1, Hour
  7, Minute 30; no `RunAtLoad`; both output paths `/dev/null`. The header comment follows
  `be.netronix.codex-memory-share.plist.tmpl` and names the spec and the `bootstrap`,
  `kickstart` and `bootout` commands.

- [ ] **Step 1: Add the failing cases:** the rendered plist passes `plutil -lint` and holds the
  label, the program path and the three calendar values; a scratch source holding only
  `.chezmoiignore`, `.chezmoidata/` and the plist lists the plist as ignored
  (`command chezmoi --source <scratch> ignored`) when `research_host` is another name, and not
  when it is this machine's `hostname -s`; exit 2 with `INCONCLUSIVE:` when `chezmoi` is absent.
- [ ] **Step 2: Run the suite.** Expected: the new cases fail.
- [ ] **Step 3: Write the plist, the data line and the ignore rule.** Run the suite and
  `./tests/run.sh provision`. Expected: pass (`machines.toml` is `provision`'s subject).
- [ ] **Step 4: `AGENTS.md`:** one Rules bullet (what `weekly-research` is, that the list and
  the prompt change only by commit, that agents never load the LaunchAgent or run the job for
  real, that moving `research_host` needs a `bootout` and the old plist removed on the old
  machine), a Layout line for `dot_config/weekly-research/`, and the live suite's row in the
  Testing table (Task 6 names it: unsandboxed + model; run after each Claude Code upgrade).
- [ ] **Step 5: Commit:** "Schedule weekly research on the research host".

### Task 6: The live suite

**Depends on:** Task 4 (the whole wrapper), Task 5 (the `AGENTS.md` row)

**Files:**
- Create: `tests/live-weekly-research.test.sh` (bash, 755, second line
  `# test-requires: unsandboxed, model  # sandbox-exec cannot start inside the sandbox; spends two haiku calls`)
- Modify: `.scripts/test-audit/subjects.tsv`, `tests/missing-subject.test.sh`

**Interfaces:**
- Consumes: the real wrapper with `WEEKLY_RESEARCH_CONFIG`, `_STATE` and `_INBOX` pointing into
  a scratch directory, `WEEKLY_RESEARCH_MODEL=haiku`, `WEEKLY_RESEARCH_BUDGET=0.5`, and the real
  `HOME` (the login).

- [ ] **Step 1: Write the suite.**
  - Guard: exit 2 with `INCONCLUSIVE:` when `sandbox-exec -p '(version 1)(allow default)'
    /usr/bin/true` fails (the suite is running sandboxed), or when `claude`, the wrapper, the
    proxy or `network.sb` is missing from the checkout.
  - Staging, as in Global constraints: the checkout's two scripts in a scratch `bin/`, its
    `network.sb` in a scratch config folder.
  - Profile rows, no model: Task 2's four `curl` checks against the staged `network.sb` and
    the staged proxy.
  - Wrapper rows: the staged wrapper, the scratch config with that `network.sb`, a two-row list
    (`https://example.com`, `http://localtest.me/`) and a short prompt that asks for both to be
    fetched and for the body shape. Expected: `last-run` says `result=ok`; the note exists;
    the proxy log has an `allow` for `example.com:443` and a `deny` for `localtest.me`; the
    saved stream's init line passes the wrapper's own check (the run did not fail on it);
    nothing was written outside the scratch directory's state and inbox.
- [ ] **Step 2: Run it unsandboxed:** `./tests/run.sh live-weekly-research`. Expected: pass. A
  subagent that cannot run unsandboxed reports that; the controller runs it.
- [ ] **Step 3: Add the map and missing-subject rows; run** `./tests/run.sh --changed`.
  Expected: every suite passes; quote the `needs: heavy` lines in the report.
- [ ] **Step 4: Commit:** "Add the live weekly research suite".

---

## After the tasks

1. A cold whole-branch review (`sp-architect`), then the pre-merge cross-review:
   `xreview dispatch --checkpoint pre-merge --diff origin/main...feat/weekly-research`.
2. In the final commit: the spec's `**Status:** Implemented` with the PR, this plan's status
   `Completed`.
3. Push the branch, open the PR against `main`, ready for review, assigned to Michael, with
   his four steps from the spec's "Michael's steps" in the body. No agent loads the schedule.
