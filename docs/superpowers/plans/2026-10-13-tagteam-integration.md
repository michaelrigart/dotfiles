# tagteam integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress

**Goal:** Fit tagteam into the dotfiles. Its plaintext logins and Keychain secrets stay out of
agent reads and transcripts, the statusline shows the live account and its usage, and its
auto-switch settings are managed in chezmoi.

**Architecture:** Four independent changes:
1. deny rules in the Claude Code settings modify script;
2. a new segment in the existing statusline script;
3. a new chezmoi-managed tagteam `config.toml`;
4. more probes in the live credential-boundary suite.

Each change carries its own test.

**Tech Stack:** chezmoi source tree, bash 3.2 (`/bin/bash`, which runs the statusline), jq,
tagteam 20261013.2030.0, shell test suites under `tests/`.

**Spec:** `docs/superpowers/specs/2026-10-13-tagteam-integration-design.md`. It is Approved;
read it first.

## Global Constraints

- **Public repository:** nothing private is committed. No account emails and no tokens, not
  even in fixtures: use `work` and `personal` as account names.
- **Suites** live in `tests/<subject>.test.sh` with mode 755 and a correct shebang.
  - Run them by executing them (`./tests/x.test.sh`), never through an interpreter.
  - A suite whose target file is missing exits 2.
  - A suite prints `  PASS: …` / `  FAIL: …` lines, or `KEY=VALUE` for the live suites, and
    exits with its failure count.
- **No new prompts:** deny rules only, never `ask` rules.
- **The statusline must run under `/bin/bash` 3.2.** No `declare -A`, no `${x,,}`, no
  `mapfile`. Its source stays pure ASCII: non-ASCII glyphs come from `printf` byte escapes,
  as the existing script does.
- **Settings change through chezmoi:** nothing writes a deployed file under `~`.
- **Implementers neither commit nor push.** Each runs only the suite named in its own task.
  The controller commits each task separately and runs the full suite once.

## Review Focus

1. **Decimal percentages:** `89.6%` stays teal, `90.4%` turns red. The colour is decided by
   the integer part, compared with `>= 90`. Test in Task 2.
2. **ANSI escapes in tagteam's output** despite `--no-color`, for example from a future
   release. They are stripped before display and before the width calculation, so the line
   still ends exactly at `COLUMNS`. Test in Task 2.
3. **Multi-line output:** only the first line is used. Test in Task 2.
4. **A line with no percentage** (for example `work · no usage yet`): it shows in teal and
   nothing errors. Test in Task 2.
5. **tagteam failing inside the sandbox:** exit 1, with `store error …` on stderr. The stderr
   text never appears in the statusline, and the output is byte-identical to a run without
   tagteam. Test in Task 2.

---

### Task 1: Deny rules for tagteam's credentials and Keychain reads

**Depends on:** none

**Files:**
- Modify: `dot_claude/modify_private_settings.json` (the `"deny": [` array; insert after the
  line `"Bash(basecamp auth token*)",`, currently line 102)
- Test: `tests/claude-settings.test.sh` (`EXP_DENY`, currently lines 25–37)

**Interfaces:**
- Consumes: nothing.
- Produces: the deployed `permissions.deny` gains exactly the 17 rules below. Claude Code
  copies the `Read()` rules into the sandbox's read-deny list by itself.

- [ ] **Step 1: Write the failing test.** In `tests/claude-settings.test.sh`, replace the
  `EXP_DENY` line `"Bash(basecamp auth token*)",` with:

```
 "Bash(basecamp auth token*)",
 "Read(~/.local/share/tagteam/rescue/**)","Edit(~/.local/share/tagteam/rescue/**)",
 "Read(~/.local/share/tagteam/displaced/**)","Edit(~/.local/share/tagteam/displaced/**)",
 "Read(~/.local/share/tagteam/sessions/*/.credentials.json)","Edit(~/.local/share/tagteam/sessions/*/.credentials.json)",
 "Bash(tagteam *export*)",
 "Bash(security *find-generic-password*)","Bash(/usr/bin/security *find-generic-password*)",
 "Bash(security *find-internet-password*)","Bash(/usr/bin/security *find-internet-password*)",
 "Bash(security *dump-keychain*)","Bash(/usr/bin/security *dump-keychain*)",
 "Bash(security *export*)","Bash(/usr/bin/security *export*)",
```

- [ ] **Step 2: Run the test and confirm it fails.**

Run: `./tests/claude-settings.test.sh`
Expected: FAIL on the section A exact-array comparison of the deny list; every other
assertion passes.

- [ ] **Step 3: Implement.** In `dot_claude/modify_private_settings.json`, directly after the
  line `"Bash(basecamp auth token*)",` inside `"deny": [`, insert the block below, indented 10
  spaces like its neighbours.

  The whole jq program in that file is one single-quoted shell string, so **no apostrophe may
  appear anywhere in it, comments included**: one would end the string and break the modifier.
  The block below has none. Keep it that way if you reword anything.

```
          # tagteam can hold a login in plaintext in three places: rescue/, displaced/ and
          # each tagteam run profile. A Read() deny is also copied into the sandbox
          # read-deny list, so this covers sandboxed Bash as well as the Read tool.
          "Read(~/.local/share/tagteam/rescue/**)",    "Edit(~/.local/share/tagteam/rescue/**)",
          "Read(~/.local/share/tagteam/displaced/**)", "Edit(~/.local/share/tagteam/displaced/**)",
          "Read(~/.local/share/tagteam/sessions/*/.credentials.json)",
          "Edit(~/.local/share/tagteam/sessions/*/.credentials.json)",
          # Keychain secrets never enter the transcript: the logins tagteam stores, the
          # Claude Code login and the gh and glab tokens all sit in the login Keychain,
          # which the sandbox does not cover. This keeps them out of the transcript only;
          # a script can still call security. Accepted as known in the tagteam
          # integration spec. The leading * also catches a global option before the verb.
          "Bash(tagteam *export*)",
          "Bash(security *find-generic-password*)",  "Bash(/usr/bin/security *find-generic-password*)",
          "Bash(security *find-internet-password*)", "Bash(/usr/bin/security *find-internet-password*)",
          "Bash(security *dump-keychain*)",          "Bash(/usr/bin/security *dump-keychain*)",
          "Bash(security *export*)",                 "Bash(/usr/bin/security *export*)",
```

- [ ] **Step 4: Run the test and confirm it passes.**

Run: `./tests/claude-settings.test.sh`
Expected: every assertion passes; report passed/total.

- [ ] **Step 5: Report.** List the changed files and the passed/total figure. Do not commit.

---

### Task 2: tagteam segment in the statusline

**Depends on:** none

**Files:**
- Modify: `dot_claude/executable_statusline.sh`
- Create: `tests/statusline.test.sh` (mode 755)

**Interfaces:**
- Consumes: `tagteam --no-color statusline`, whose default output is
  `{account} · 5h {5h}% · 7d {7d}%{stale}`. It exits non-zero on failure; inside the sandbox
  it exits 1 with `tagteam: store error: unable to open database file` on stderr.
- Produces: nothing other tasks use.

- [ ] **Step 1: Write the failing test.** Create `tests/statusline.test.sh`:

```bash
#!/usr/bin/env bash
# Feeds a session JSON through dot_claude/executable_statusline.sh with a stub tagteam on
# PATH and checks the tagteam segment:
#   - shown in teal, and in red once a percentage reaches 90;
#   - left out when tagteam is absent, fails or prints nothing, and when it would not fit.
# Left out means byte-identical to a run without tagteam.
# Runs under /bin/bash, the bash that runs the statusline in practice.
#
#   ./tests/statusline.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SL="$SRC/dot_claude/executable_statusline.sh"
[ -f "$SL" ] || { echo "missing script under test: $SL" >&2; exit 2; }
JQ="$(command -v jq)" || { echo "jq is required" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/statusline.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/none" "$T/tt" "$T/a-rather-long-project-directory-name"
ln -s "$JQ" "$T/none/jq"
ln -s "$JQ" "$T/tt/jq"
cat > "$T/tt/tagteam" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$STUB_ARGS"
[ -n "${TT_ERR:-}" ] && printf '%s\n' "$TT_ERR" >&2
[ -n "${TT_OUT:-}" ] && printf '%b' "$TT_OUT"
exit "${TT_RC:-0}"
EOF
chmod 755 "$T/tt/tagteam"

DOT=$(printf '\xc2\xb7')
TEAL='38;2;115;218;202'
RED='38;2;247;118;142'
INPUT=$(printf '{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"workspace":{"current_dir":"%s"}}' \
  "$T/a-rather-long-project-directory-name")

# run <bin: none|tt> <cols> [TT_OUT] [TT_RC] [TT_ERR] -> the statusline's stdout.
# Its stderr goes to $T/stderr, so a leak can be asserted on.
run() {
  printf '%s' "$INPUT" | env -i HOME="$T" PATH="$T/$1:/usr/bin:/bin" COLUMNS="$2" \
    STUB_ARGS="$T/args" TT_OUT="${3:-}" TT_RC="${4:-0}" TT_ERR="${5:-}" bash "$SL" 2>"$T/stderr"
}
strip() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }
vis()   { strip "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' '; }
has()   { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

TT="work $DOT 5h 31% $DOT 7d 12%"

# --- shown, teal, full width, called as `tagteam --no-color statusline` ---
out=$(run tt 200 "$TT\n")
if has "$out" "$TEAL" && has "$(strip "$out")" "$TT" && [ "$(vis "$out")" = 200 ]; then
  _pass "the segment shows the account and usage in teal, full width"
else _fail "teal segment at 200 columns" "$(strip "$out")"; fi
if [ "$(cat "$T/args")" = "--no-color statusline" ]; then
  _pass "tagteam is called as: tagteam --no-color statusline"
else _fail "tagteam arguments" "$(cat "$T/args")"; fi

# --- red from 90% (integer part decides) ---
for pct in 90 92 90.4; do
  out=$(run tt 200 "work $DOT 5h 25% $DOT 7d $pct%\n")
  if has "$out" "$RED" && ! has "$out" "$TEAL"; then _pass "$pct% turns the segment red"
  else _fail "$pct% should be red" "$(strip "$out")"; fi
done
for pct in 89 89.6; do
  out=$(run tt 200 "work $DOT 5h 25% $DOT 7d $pct%\n")
  if has "$out" "$TEAL" && ! has "$out" "$RED"; then _pass "$pct% stays teal"
  else _fail "$pct% should be teal" "$(strip "$out")"; fi
done

# --- no percentage at all: teal, no error ---
out=$(run tt 200 "work $DOT no usage yet\n")
if has "$out" "$TEAL" && has "$(strip "$out")" "work $DOT no usage yet"; then
  _pass "a line without percentages shows in teal"
else _fail "line without percentages" "$(strip "$out")"; fi

# --- ANSI in tagteam's output is stripped: the raw bytes equal the plain-output run ---
plain_run=$(run tt 200 "$TT\n")
out=$(run tt 200 "\033[1mwork\033[0m $DOT 5h 31% $DOT 7d 12%\n")
if has "$(strip "$plain_run")" "$TT" && [ "$out" = "$plain_run" ]; then
  _pass "ANSI escapes in tagteam's output are stripped (byte-identical to plain output)"
else _fail "ANSI in tagteam output must not reach the statusline" "$(printf '%s' "$out" | od -c | head -3)"; fi

# --- only the first line is used ---
out=$(run tt 200 "$TT\nsecond line\n")
if has "$(strip "$out")" "$TT" && ! has "$(strip "$out")" "second line"; then
  _pass "only the first line of tagteam's output is used"
else _fail "multi-line output" "$(strip "$out")"; fi

# --- left out: byte-identical to a run without tagteam ---
ref=$(run none 200)
if ! has "$ref" "$TEAL" && ! has "$ref" "$RED"; then _pass "without tagteam there is no segment"
else _fail "segment without tagteam" "$(strip "$ref")"; fi
out=$(run tt 200 "$TT\n" 1 "tagteam: store error: unable to open database file")
if [ "$out" = "$ref" ]; then _pass "exit 1 (sandboxed store error) leaves the line unchanged"
else _fail "exit 1 should leave the line unchanged" "$(strip "$out")"; fi
if [ ! -s "$T/stderr" ]; then _pass "tagteam's stderr never reaches the statusline's stderr"
else _fail "tagteam stderr leaked" "$(cat "$T/stderr")"; fi
out=$(run tt 200 "")
if [ "$out" = "$ref" ]; then _pass "empty output leaves the line unchanged"
else _fail "empty output should leave the line unchanged" "$(strip "$out")"; fi

# --- the fit boundary ---
# Cluster width without tagteam, from a wide run: total = cols = w + 1 (separator) + pad.
wide=$(strip "$(run none 500)")
trail=${wide##*[! ]}
base_w=$((500 - 1 - ${#trail}))
tt_w=$(printf '%s' "$TT" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' ')
with_w=$((base_w + tt_w + 3))   # separator + space + text + space
fit=$((with_w + 2))
out=$(run tt "$fit" "$TT\n")
if has "$(strip "$out")" "$TT" && [ "$(vis "$out")" = "$fit" ]; then
  _pass "at COLUMNS - 2 the segment is shown and the line is exactly $fit wide"
else _fail "segment should fit at $fit columns" "$(strip "$out")"; fi
tight=$((with_w + 1))
out=$(run tt "$tight" "$TT\n")
if [ "$out" = "$(run none "$tight")" ]; then
  _pass "at COLUMNS - 1 the segment is left out and the line is byte-identical"
else _fail "segment should be left out at $tight columns" "$(strip "$out")"; fi

echo "statusline: $pass passed, $fail failed"
exit "$fail"
```

- [ ] **Step 2: Run the test and confirm it fails.**

Run: `chmod 755 tests/statusline.test.sh && ./tests/statusline.test.sh`
Expected: the tests that need the segment fail: teal, arguments, red, no percentage, ANSI
(it requires the segment in the plain run), multi-line, and fit at COLUMNS - 2. The left-out
cases already pass, stderr included.

- [ ] **Step 3: Implement.** In `dot_claude/executable_statusline.sh`:

  (a) Add two palette entries directly after the `YELLOW=` line:

```bash
TEAL="115;218;202"    # #73daca  tagteam account + usage text
RED="247;118;142"     # #f7768e  the same at 90% or more
```

  (b) Replace everything from the line `# segments: "fg|bg|text"  (';' is used inside colors, so '|' is a safe delimiter)`
  through the line `w=$((w))` (the segment list, the model segment, the render loop and the
  width count) with:

```bash
# --- tagteam: the live account and its usage. Empty when tagteam is missing, fails (it
# cannot open its store inside the sandbox) or prints nothing; then no segment is shown. ---
tt=""
if command -v tagteam >/dev/null 2>&1; then
  tt=$(tagteam --no-color statusline </dev/null 2>/dev/null) || tt=""
  tt=${tt%%$'\n'*}
  tt=$(printf '%s' "$tt" | sed $'s/\033\\[[0-9;]*m//g')
fi
tt_fg=$TEAL
if [ -n "$tt" ]; then
  max=$(printf '%s' "$tt" | grep -oE '[0-9]+(\.[0-9]+)?%' | cut -d. -f1 | tr -d '%' | sort -n | tail -1)
  [ -n "$max" ] && [ "$max" -ge 90 ] && tt_fg=$RED
fi

# model, with the live reasoning effort beside it in muted yellow (omitted when
# the model doesn't expose an effort level, i.e. .effort.level is absent)
model_seg="$model"
[ -n "$effort" ] && model_seg="$model $(printf '\033[38;2;%sm' "$YELLOW")$DOT $effort"

# segments: "fg|bg|text"  (';' is used inside colors, so '|' is a safe delimiter)
# build_segs <0|1>: 1 adds the tagteam segment after the model; the skill segment then
# takes the NIGHT shade so neighbouring backgrounds keep alternating.
build_segs() {
  local skill_bg=$BGHL
  segs=()
  segs+=("$BLUE|$NIGHT|$dir")
  [ -n "$branch" ] && segs+=("$GREEN|$BGHL|$BR $branch")
  segs+=("$CYAN|$NIGHT|$model_seg")
  if [ "$1" = 1 ]; then
    segs+=("$tt_fg|$BGHL|$tt")
    skill_bg=$NIGHT
  fi
  if [ -n "$skill" ]; then
    segs+=("$MAGENTA|$skill_bg|$ARR $skill")
  else
    segs+=("$COMMENT|$skill_bg|$ARR $DASH")
  fi
}

# render: segs -> out, prevbg, and w (the cluster's visible width). Strip ANSI, then
# count UTF-8 codepoints as the bytes that are NOT continuation bytes (0x80-0xBF).
# Locale-independent, so it is correct no matter what LC_* the harness hands us.
render() {
  local s fg rest bg text plain
  out=""; prevbg=""
  for s in "${segs[@]}"; do
    fg=${s%%|*}; rest=${s#*|}; bg=${rest%%|*}; text=${rest#*|}
    [ -n "$prevbg" ] && out+=$'\033['"38;2;${prevbg};48;2;${bg}m${SEP}"
    out+=$'\033['"38;2;${fg};48;2;${bg}m ${text} "
    prevbg=$bg
  done
  plain=$(printf '%s' "$out" | sed $'s/\033\\[[0-9;]*m//g')
  w=$(printf '%s' "$plain" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c)
  w=$((w))
}

# The renderer never truncates, so the tagteam segment is kept only when the closing
# separator and at least one column of filler still fit: then the line ends exactly at
# $cols. Otherwise the line is what it was without tagteam.
if [ -n "$tt" ]; then
  build_segs 1; render
  [ "$w" -le $((cols - 2)) ] || { build_segs 0; render; }
else
  build_segs 0; render
fi
```

  Leave the filler-bar block that follows (`# filler bar to the right edge …`) and the final
  `printf` unchanged.

- [ ] **Step 4: Run the test and confirm it passes.**

Run: `./tests/statusline.test.sh`
Expected: every assertion passes; report passed/total.

- [ ] **Step 5: Check that nothing else changed when no tagteam segment is shown.**

Never use `git stash` here: other implementers are editing the same checkout. Read the old
version from git instead:

```bash
git show HEAD:dot_claude/executable_statusline.sh > "$TMPDIR/sl-old.sh"
J='{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp"}}'
P="/usr/bin:/bin:$(dirname "$(command -v jq)")"
printf '%s' "$J" | env -i PATH="$P" COLUMNS=120 bash "$TMPDIR/sl-old.sh" > "$TMPDIR/sl-before"
printf '%s' "$J" | env -i PATH="$P" COLUMNS=120 bash dot_claude/executable_statusline.sh > "$TMPDIR/sl-after"
cmp "$TMPDIR/sl-before" "$TMPDIR/sl-after" && echo identical
```

Expected: `identical`. That PATH holds no tagteam, so the output must be byte-identical to the
old script's. If the jq directory also holds a `tagteam` (for example `/opt/homebrew/bin`),
symlink jq into an empty temporary directory and use that directory instead.

- [ ] **Step 6: Report.** List the changed files and the passed/total figure. Do not commit.

---

### Task 3: chezmoi-managed tagteam settings

**Depends on:** none

**Files:**
- Create: `dot_config/private_tagteam/private_config.toml`. The `private_` prefixes deploy
  `~/.config/tagteam` as mode 0700 and `config.toml` as 0600, which `tagteam doctor` requires.
- Create: `tests/tagteam-config.test.sh` (mode 755)

**Interfaces:**
- Consumes: `tagteam config list --json`. It prints
  `{"keys":[{"key":…,"value":…,"default":…,"source":"default"|"global"|"provider"}…]}` and
  honours `XDG_CONFIG_HOME`.
- Produces: the deployed `~/.config/tagteam/config.toml`. A later launchd auto-switch agent
  will read it.

- [ ] **Step 1: Write the failing test.** Create `tests/tagteam-config.test.sh`:

```bash
#!/usr/bin/env bash
# Checks the chezmoi-managed tagteam settings with tagteam itself. A copy of the source file
# is read through XDG_CONFIG_HOME; it must yield threshold 95 and strategy consume-first,
# both from the file (source "global"), and leave every other key at its default. The
# source path carries private_ on the directory and the file, so chezmoi deploys them
# 0700/0600 as `tagteam doctor` requires; a rename away from that fails the existence check.
#
#   ./tests/tagteam-config.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$SRC/dot_config/private_tagteam/private_config.toml"
[ -f "$CFG" ] || { echo "missing file under test: $CFG" >&2; exit 2; }
command -v tagteam >/dev/null 2>&1 || { echo "tagteam is not installed (Brewfile)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/tagteam-config.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tagteam"
cp "$CFG" "$T/tagteam/config.toml"
json=$(XDG_CONFIG_HOME="$T" tagteam config list --json 2>&1) || { _fail "tagteam config list" "$json"; json='{}'; }

if printf '%s' "$json" | jq -e '.keys[] | select(.key == "autoswitch.threshold") | .value == 95 and .source == "global"' >/dev/null; then
  _pass "autoswitch.threshold is 95, from the file"
else _fail "autoswitch.threshold" "$(printf '%s' "$json" | jq -c '.keys[]? | select(.key == "autoswitch.threshold")')"; fi

if printf '%s' "$json" | jq -e '.keys[] | select(.key == "autoswitch.strategy") | .value == "consume-first" and .source == "global"' >/dev/null; then
  _pass "autoswitch.strategy is consume-first, from the file"
else _fail "autoswitch.strategy" "$(printf '%s' "$json" | jq -c '.keys[]? | select(.key == "autoswitch.strategy")')"; fi

others=$(printf '%s' "$json" | jq -c '[.keys[]? | select(.source != "default") | .key] | sort')
if [ "$others" = '["autoswitch.strategy","autoswitch.threshold"]' ]; then
  _pass "no other key leaves its default"
else _fail "only the two autoswitch keys may be set" "$others"; fi

echo "tagteam-config: $pass passed, $fail failed"
exit "$fail"
```

- [ ] **Step 2: Run the test and confirm it exits 2.**

Run: `chmod 755 tests/tagteam-config.test.sh && ./tests/tagteam-config.test.sh; echo "exit $?"`
Expected: `missing file under test: …/dot_config/private_tagteam/private_config.toml`,
then `exit 2`.

- [ ] **Step 3: Implement.** Create `dot_config/private_tagteam/private_config.toml`:

```toml
# tagteam settings, managed by chezmoi: edit the source in the dotfiles, not this file.
# A `tagteam config set` is overwritten by the next `chezmoi apply`.
# Spec: docs/superpowers/specs/2026-10-13-tagteam-integration-design.md

[autoswitch]
# Switch away above 95% of a window (tagteam's default is 90).
threshold = 95
# Use up the account whose weekly window resets soonest first, so less capacity expires
# unused; the weekly window is the one that runs out.
strategy = "consume-first"
```

- [ ] **Step 4: Run the test and confirm it passes.**

Run: `./tests/tagteam-config.test.sh`
Expected: 3 passed, 0 failed.

- [ ] **Step 5: Confirm chezmoi renders the target.**

Run: `chezmoi --source "$PWD" cat ~/.config/tagteam/config.toml`
Expected: the file's contents. If chezmoi fails only because the sandbox stops it reading its
own config or 1Password, report that and continue.

- [ ] **Step 6: Report.** List the changed files and the passed/total figure. Do not commit.

---

### Task 4: tagteam probes in the live credential-boundary suite

**Depends on:** none

**Files:**
- Modify: `tests/live-credential-boundary.test.sh` (insert before the final `exit "$fail"`)

**Interfaces:**
- Consumes: tagteam's data directory, `${XDG_DATA_HOME:-$HOME/.local/share}/tagteam`,
  resolved the same way tagteam resolves it.
- Produces: three new `KEY=VALUE` lines: `TAGTEAM_RESCUE`, `TAGTEAM_DISPLACED`,
  `TAGTEAM_SESSION_CREDENTIALS`. Each value is `READABLE`, `DENIED` or `ABSENT`, and only
  `READABLE` adds to the failure count.

- [ ] **Step 1: Write the probes.** Insert directly before the last line, `exit "$fail"`:

```bash
# tagteam can hold a login in plaintext in three places. A path that does not exist yet was
# not measured (ABSENT); only a readable one is a failure. The sandbox answers ENOENT for a
# missing path even under a deny, and EPERM for an existing denied one, so the error text
# tells the two apart. A sandboxed suite cannot create a fixture there itself.
TT_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/tagteam"

probe_dir() { # probe_dir <KEY> <dir>
  local key=$1 dir=$2 err f st=ABSENT
  if err=$(/bin/ls -A "$dir" 2>&1 >/dev/null); then
    for f in "$dir"/* "$dir"/.[!.]*; do
      [ -f "$f" ] || continue
      if dd if="$f" of=/dev/null bs=1 count=1 2>/dev/null; then st=READABLE; break; fi
      st=DENIED
    done
  else
    case "$err" in *"No such file"*) st=ABSENT ;; *) st=DENIED ;; esac
  fi
  echo "$key=$st"
  [ "$st" = READABLE ] && fail=$((fail + 1))
  return 0
}
probe_dir TAGTEAM_RESCUE "$TT_DATA/rescue"
probe_dir TAGTEAM_DISPLACED "$TT_DATA/displaced"

st=ABSENT
for f in "$TT_DATA"/sessions/*/.credentials.json; do
  case "$f" in *'*'*) continue ;; esac   # the glob matched nothing
  if err=$(dd if="$f" of=/dev/null bs=1 count=1 2>&1 >/dev/null); then st=READABLE; break; fi
  case "$err" in *"No such file"*) ;; *) st=DENIED ;; esac
done
echo "TAGTEAM_SESSION_CREDENTIALS=$st"
[ "$st" = READABLE ] && fail=$((fail + 1))
```

Also change the header's second line from `# Run inside a fresh Claude sandbox. Reads at most one byte to /dev/null and reports only`
to `# Run inside a fresh Claude sandbox. Reads at most one byte per file to /dev/null and reports only`.

- [ ] **Step 2: Check the probe logic against fixtures.** The real paths cannot be fixtured
  from inside the sandbox, so point `XDG_DATA_HOME` at a temporary tree. The SSH lines report
  as they normally do; read only the three `TAGTEAM_` lines:

```bash
F="$(mktemp -d "${TMPDIR:-/tmp}/tt-boundary.XXXXXX")"
XDG_DATA_HOME="$F" ./tests/live-credential-boundary.test.sh | grep '^TAGTEAM_'
# expect: TAGTEAM_RESCUE=ABSENT, TAGTEAM_DISPLACED=ABSENT, TAGTEAM_SESSION_CREDENTIALS=ABSENT
mkdir -p "$F/tagteam/rescue" "$F/tagteam/displaced" "$F/tagteam/sessions/abc"
printf x > "$F/tagteam/rescue/probe"; printf x > "$F/tagteam/sessions/abc/.credentials.json"
XDG_DATA_HOME="$F" ./tests/live-credential-boundary.test.sh | grep '^TAGTEAM_'
# expect: TAGTEAM_RESCUE=READABLE, TAGTEAM_DISPLACED=ABSENT, TAGTEAM_SESSION_CREDENTIALS=READABLE
rm -rf "$F"
```

Expected: exactly the lines in the comments. An empty existing directory reports `ABSENT`,
because there was nothing to measure.

- [ ] **Step 3: Lint.**

Run: `git show HEAD:tests/live-credential-boundary.test.sh > "$TMPDIR/lcb-old.sh"`, then
`shellcheck "$TMPDIR/lcb-old.sh"` and `shellcheck tests/live-credential-boundary.test.sh`.
Expected: no warning in the new file that the old one did not have. Fix any new warning.
Never use `git stash`: other implementers are editing the same checkout.

- [ ] **Step 4: Report.** List the changed file, the fixture output and the shellcheck
  result. Do not commit.

---

## Execution

All four tasks touch disjoint files, and no task's test loads another task's file. They form
one batch, run in parallel in this checkout on branch `feat/tagteam-integration`. The
controller then:

1. Commits each task on its own, re-checking `git branch --show-current` before each commit.
2. Reviews each task on exactly its commit.
3. Runs `./tests/run.sh` once for the batch and reports passed/total.
4. Runs the pre-merge cross-review, `main...feat/tagteam-integration`, and pushes the branch.

## After merge (Michael, or the next session)

These are the spec's live checks. They need the merged settings deployed and a fresh
session, so they cannot run before the merge:

1. Run `chezmoi apply`, then start a fresh Claude Code session.
2. **Boundary:** plant `~/.local/share/tagteam/rescue/.boundary-probe` outside the sandbox
   (for example in a plain terminal). In the fresh sandboxed session, run
   `./tests/run.sh live-credential-boundary`; expect `TAGTEAM_RESCUE=DENIED` and exit 0.
   Then remove the probe file.
3. **Statusline:** it shows `work · 5h …% · 7d …%`, or the aliases of your own accounts.
4. **Settings:** `tagteam config list` shows `autoswitch.threshold` 95 and
   `autoswitch.strategy` consume-first, both with source `global`.
5. **Doctor:** `tagteam doctor` reports "the store, the vault and tagteam's directories are
   private".
