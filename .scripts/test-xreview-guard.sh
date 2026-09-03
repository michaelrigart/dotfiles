#!/usr/bin/env bash
# Tests for dot_claude/executable_xreview-guard.sh — the pre-merge cross-review gate.
#
# Fixtures are real git repos under $TMPDIR with a fake XDG_STATE_HOME, so the guard's
# receipt lookup is exercised for real rather than mocked. Every assertion pins an exact
# decision string: "did not crash" is not evidence a guard fired.
#
# Most of these cases pin the ALLOW side. The guard fires on every Bash call, and its
# first shipped matcher was a substring glob (`*gh*pr*create*`) that read "gh" out of
# "outright", "pr" out of "proposed" and "create" out of "recreate" — so writing a
# Basecamp comment about a branch was denied with a message about cross-review.
# Measured over the recorded transcripts on 2026-09-03: nine false denies to five real
# ones. A guard that stops unrelated work is worse than no guard.
set -uo pipefail
GUARD="$(cd "$(dirname "$0")/.." && pwd)/dot_claude/executable_xreview-guard.sh"
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

# jq builds the payload rather than printf: these commands carry quotes, newlines and
# heredocs, and hand-escaping them into a JSON string is how a test ends up asserting
# against a command the guard never saw.
payload() { jq -n --arg c "$1" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}'; }
# An allow is silence, not JSON — jq on empty stdin prints nothing, so the empty case
# must be handled before jq rather than by its // default.
decide() {
  local out; out="$(cat)"
  [ -n "$out" ] || { printf 'allow'; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null \
    || printf 'allow'
}
# The payload is materialised before the pipeline: the guard exits without reading
# stdin on the bypass path, and jq writing into a closed pipe prints an error that
# looks like a test failure. printf is a builtin and stays quiet.
decision() { local p; p="$(payload "$1")"; printf '%s' "$p" | bash "$GUARD" 2>/dev/null | decide; }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xrguard.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state"
mkdir -p "$ROOT/repo" && cd "$ROOT/repo" || exit 1
git init -q . && git config user.email t@t && git config user.name t
git config commit.gpgsign false          # see test-xreview.sh for why
if ! git commit -q --allow-empty -m init; then printf 'fixture setup failed\n' >&2; exit 1; fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
KEY="$(printf '%s' "$(git rev-parse --show-toplevel)" | tr '/' '_' | sed 's/^_//')"
RECEIPTS="$XDG_STATE_HOME/xreview/$KEY/reviews.jsonl"

# ------------------------------------------------------------------ the gate itself
is "glab mr create is denied with no receipt"  "$(decision 'glab mr create --fill')" deny
is "gh pr create is denied with no receipt"    "$(decision 'gh pr create --fill')"   deny
is "an unrelated command is allowed"           "$(decision 'git status')"            allow
is "git merge is out of scope and allowed"     "$(decision 'git merge feature')"     allow

# The real-world shape: the body is written to the scratchpad first, so the verb sits on
# its own line after an assignment rather than at the start of the command.
is "the verb after an assignment on a previous line is denied" \
  "$(decision 'SP=/tmp/scratch
glab mr create --description "$(cat "$SP/mr-body.md")" --yes')" deny
is "the verb after a pipe is denied" \
  "$(decision 'printf body | gh pr create --fill --body-file -')" deny

# ------------------------------------------------- text that merely MENTIONS the verb
# Each of these was denied in a real session. The letters are all present and in order;
# none of them is a command that opens anything.
is "a Basecamp comment whose prose contains gh/pr/create is allowed" \
  "$(decision "printf '%s\\n' 'The runner outright refuses the proposed patch; recreate the cache.' | basecamp comments create 10268194367 - --in 47577890")" allow
is "writing an MR body that quotes the command inline is allowed" \
  "$(decision 'cat > "$TMPDIR/mr-body.md" <<'"'"'EOF'"'"'
**Story**: [Basecamp](https://app.basecamp.com/1/x)

Rendered locally, then passed with `glab mr create --description "$(cat ...)"`.
EOF')" allow
is "grepping for the literal command is allowed" \
  "$(decision "rg 'gh pr create' docs/")" allow
is "a card comment about a GitHub download is allowed" \
  "$(decision "printf '%s' '<p>Weights were fetched from <strong>github.com/ultralytics/assets</strong>; the proposed change recreates that path.</p>' | basecamp comments create 1 - --in 2")" allow

# ------------------------------------------------------------------------- receipts
mkdir -p "$(dirname "$RECEIPTS")"
printf '{"ts":"t","branch":"other","head":"h","thread":"x","nonce":"n"}\n' > "$RECEIPTS"
is "a receipt for a DIFFERENT branch still denies" "$(decision 'glab mr create')" deny

printf '{"ts":"t","branch":"%s","head":"h","thread":"x","nonce":"n"}\n' "$BRANCH" >> "$RECEIPTS"
is "a receipt for this branch allows"          "$(decision 'glab mr create')" allow

# --------------------------------------------------------------------- the bypass
# The deny message tells the model to set XREVIEW_GUARD=off. The only place a model CAN
# set it is the command it is running, so that is the form that has to work — reading it
# from the hook's own environment makes the documented escape hatch unreachable. Recorded
# 2026-09-02 in opsmaster: `XREVIEW_GUARD=off glab mr create …`, sent on Michael's
# explicit instruction to merge without a review, denied anyway.
rm -f "$RECEIPTS"
is "XREVIEW_GUARD=off in the command bypasses" \
  "$(decision 'XREVIEW_GUARD=off glab mr create --fill')" allow
is "XREVIEW_GUARD=off mid-command bypasses" \
  "$(decision 'cd /tmp && XREVIEW_GUARD=off glab mr create --fill')" allow
is "XREVIEW_GUARD=off in a trailing comment bypasses" \
  "$(decision 'glab mr create --fill # XREVIEW_GUARD=off')" allow

XREVIEW_GUARD=off
export XREVIEW_GUARD
is "XREVIEW_GUARD=off in the environment bypasses"  "$(decision 'glab mr create')" allow
unset XREVIEW_GUARD

is "an empty payload fails open"  "$(printf '' | bash "$GUARD" 2>/dev/null | decide)" allow

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
