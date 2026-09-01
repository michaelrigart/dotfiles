#!/usr/bin/env bash
# Tests that dot_claude/skills/cross-review/SKILL.md still describes the xreview that
# exists. The skill is executable documentation: the model reads it and acts on it, so
# a stale sentence is not a cosmetic defect, it is a wrong instruction that gets
# followed. Two have already shipped — a documented round cap of 3 after the code moved
# to 10, which would have escalated seven rounds early, and a `notify` subcommand that
# survived in the prose after being deleted from the CLI.
#
# Only one direction is asserted. Everything the skill NAMES must exist; the CLI is free
# to have subcommands the skill never mentions, because the skill is a workflow guide
# rather than a manual page.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XREVIEW="$ROOT/dot_local/bin/executable_xreview"
SKILL="$ROOT/dot_claude/skills/cross-review/SKILL.md"
# The skill documents a system, not one file: the CLI plus the two PreToolUse guards
# that enforce the parts prose cannot. XREVIEW_GUARD lives in the guards, so scoping the
# search to the CLI reports drift that is not there.
IMPL=("$XREVIEW" "$ROOT/dot_claude/executable_xreview-guard.sh" "$ROOT/dot_claude/executable_xreview-apply-guard.sh")
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | %s\n' "$1" "$2"; fail=$((fail + 1)); }

for f in "${IMPL[@]}" "$SKILL"; do
  [ -r "$f" ] || { printf 'cannot read %s\n' "$f" >&2; exit 1; }
done

# --- subcommands -------------------------------------------------------------
# The dispatch `case` is the authority: a subcommand exists iff it has an arm there.
openers="$(grep -c '^case "${1:-}" in' "$XREVIEW")"
[ "$openers" = 1 ] || {
  printf 'expected exactly one top-level dispatch case in %s, found %s — the extracted\nrange would span more than the dispatcher and an unrelated arm could satisfy a check\n' \
    "$XREVIEW" "$openers" >&2; exit 1; }
dispatch="$(sed -n '/^case "${1:-}" in/,/^esac/p' "$XREVIEW")"
[ -n "$dispatch" ] || { printf 'could not locate the dispatch case in %s\n' "$XREVIEW" >&2; exit 1; }

# Deliberately not anchored on a backtick: the skill writes its two most important
# subcommands inside fenced blocks (`NONCE=$(xreview dispatch ...)`, `xreview apply`),
# so a backtick-only extractor silently skips exactly the ones worth checking. Prose
# never produces a false hit here, because the bare word is always written `xreview`
# with its own closing backtick before the verb.
# The class deliberately swallows every identifier character. Stopping at the first
# character outside it would extract `round` from a mistyped `round_reset`, and the real
# `round)` arm would then satisfy a name that does not exist.
named="$(grep -oE 'xreview[[:space:]]+[A-Za-z][a-zA-Z0-9_-]*' "$SKILL" | awk '{print $2}' | sort -u)"
[ -n "$named" ] || { printf 'SKILL.md names no xreview subcommands — the extractor is broken\n' >&2; exit 1; }

for sub in $named; do
  if printf '%s' "$dispatch" | grep -qE "^[[:space:]]*${sub}\)"; then
    _pass "SKILL.md names '$sub', and the CLI dispatches it"
  else
    _fail "SKILL.md names '$sub', and the CLI dispatches it" \
          "no '${sub})' arm in the dispatch case — the skill sends the model at a subcommand that does not exist"
  fi
done

# --- environment variables ---------------------------------------------------
# Full-line comments are stripped first. A block explaining XREVIEW_GUARD is not a
# reader of it, and a check that accepts prose from the implementation side is asserting
# that two documents agree with each other rather than that the code does what is
# written. Only whole-line comments go: `#` inside ${var#prefix} is code, and cutting at
# it would corrupt lines that do implement something.
# Whole-line comments go, and so does a trailing ` # ...`. Anchoring the trailing cut on
# a PRECEDING space is what keeps ${var#prefix} intact — there the # follows a word
# character. Erring long here is the safe direction: over-stripping can only lose a real
# read and fail, while under-stripping lets a comment stand in for an implementation.
strip_comments() { grep -hv '^[[:space:]]*#' "$@" | sed 's/[[:space:]]#.*$//'; }
code_of() { strip_comments "${IMPL[@]}"; }
vars="$(grep -oiE 'XREVIEW_[A-Za-z0-9_]+' "$SKILL" | sort -u)"
[ -n "$vars" ] || _fail "SKILL.md still names the environment knobs" \
  "found none — either the skill stopped documenting them, or this extractor broke"
for var in $vars; do
  # `${VAR` — an expansion, not a mention. The guard's own error text says
  # "Set XREVIEW_GUARD=off to bypass deliberately", so a substring search is satisfied by
  # the message describing the feature after the code implementing it has gone.
  if code_of | grep -qE -- "\\\$\\{$var[:}]"; then
    _pass "SKILL.md names \$$var, and the implementation reads it"
  else
    _fail "SKILL.md names \$$var, and the implementation reads it" \
          "$var appears in neither the CLI nor the guards — a documented knob with nothing behind it"
  fi
done

# --- the round cap -----------------------------------------------------------
# The number in the prose drives an escalation decision, so it has to be the number the
# code enforces. Both sides are read rather than hardcoded here: a test that restated
# the value would just be a third place to update.
# Every cap statement, not the first: a second sentence saying something else means the
# skill contradicts itself, and comparing only the first would hide whichever one is
# wrong. More than one distinct value is itself the defect.
doc_caps="$(grep -oE 'capped at [0-9]+' "$SKILL" | grep -oE '[0-9]+' | sort -u)"
doc_cap="$(printf '%s' "$doc_caps" | head -1)"
doc_n="$(printf '%s\n' "$doc_caps" | grep -c '[0-9]')"
# Anchored on the assignment to `max`, which is the name the comparison uses. A second
# expansion kept for a diagnostic would otherwise report the documented number while the
# enforced one had moved.
code_cap="$(strip_comments "$XREVIEW" | grep -oE '(^|[[:space:]])max="\$\{XREVIEW_MAX_ROUNDS:-[0-9]+\}"' | grep -oE '[0-9]+' | sort -u)"
if [ "$doc_n" -gt 1 ]; then
  _fail "the documented round cap matches the code" \
        "SKILL.md states more than one cap ($(printf '%s' "$doc_caps" | tr '\n' ' ')) — it contradicts itself"
elif [ -z "$doc_cap" ] || [ -z "$code_cap" ]; then
  _fail "the documented round cap matches the code" \
        "could not read both values (doc='$doc_cap' code='$code_cap')"
elif [ "$doc_cap" = "$code_cap" ]; then
  _pass "the documented round cap ($doc_cap) matches the code"
else
  _fail "the documented round cap matches the code" \
        "SKILL.md says $doc_cap, the CLI defaults to $code_cap"
fi

# --- the operations the guard promises to deny -------------------------------
# The skill tells the model which commands are gated. If an arm is dropped there, the
# model goes on believing the gate applies and proposes a merge that was never reviewed
# — the failure this whole mechanism exists to prevent, arrived at through the prose.
GUARD="$ROOT/dot_claude/executable_xreview-guard.sh"
gated="$(grep -oE '(glab|gh)[[:space:]]+(mr|pr)[[:space:]]+create[A-Za-z0-9_-]*' "$SKILL" | tr -s ' \t' ' ' | sort -u)"
if [ -z "$gated" ]; then
  _fail "SKILL.md still names the gated forge commands" \
        "found none — either the skill stopped documenting the gate, or this extractor broke"
else
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    pat="$(printf '%s' "$c" | tr ' ' '*')"
    if strip_comments "$GUARD" | grep -qF -- "$pat"; then
      _pass "SKILL.md says '$c' is gated, and the guard matches it"
    else
      _fail "SKILL.md says '$c' is gated, and the guard matches it" \
            "no '$pat' pattern in the guard — the skill promises a gate the guard no longer applies"
    fi
  done <<< "$gated"
fi

# --- the tools the apply window confines --------------------------------------
# Same class as the forge gate, other guard: the skill tells the model its edits are
# confined to the reviewed files. If a tool falls out of the apply guard's arm, the
# model believes in a boundary that is no longer enforced.
AGUARD="$ROOT/dot_claude/executable_xreview-apply-guard.sh"
confined="$(grep -oE 'denies [A-Z][A-Za-z]*(/[A-Z][A-Za-z]*)+' "$SKILL" | sed 's/^denies //' | tr '/' '\n' | sort -u)"
if [ -z "$confined" ]; then
  _fail "SKILL.md still names the confined tools" \
        "found none — either the skill stopped documenting the apply window, or this extractor broke"
else
  for tool in $confined; do
    # The dispatching case only: a `supported="Edit|Write"` string kept for diagnostics
    # is not an arm, and matching it would let a tool fall out of the guard unnoticed.
    if strip_comments "$AGUARD" | grep -E 'case[[:space:]]+"\$tool"' | grep -qE "[|( ]$tool[|) ]"; then
      _pass "SKILL.md says '$tool' is confined, and the apply guard matches it"
    else
      _fail "SKILL.md says '$tool' is confined, and the apply guard matches it" \
            "no '$tool' arm in the apply guard — the skill promises a boundary it no longer enforces"
    fi
  done
fi

# The inline-diff flag is the whole point of the cost fix: a skill that still shows a
# bare `xreview dispatch <body-file>` teaches the expensive call, and the model follows
# the skill, not the CLI's usage line.
# Assert on the dispatch line itself, not on the file: --diff is mentioned in the prose
# too, so a file-wide grep stays green even after the example reverts to the costly form.
if grep -E '^\s*(NONCE=)?\$?\(?xreview dispatch' "$SKILL" | grep -q -- '--diff'; then
  _pass "the skill's dispatch example passes the diff inline"
else
  _fail "the skill's dispatch example passes the diff inline" \
        "$(grep -E 'xreview dispatch' "$SKILL" | head -1)"
fi
if strip_comments "$XREVIEW" | grep -q -- '--diff)'; then
  _pass "the CLI actually accepts --diff"
else
  _fail "the CLI actually accepts --diff" "no --diff case in the dispatch parser"
fi

# The staleness threshold is a number in two places. The round cap has already drifted
# once between skill and code; this one is pinned the same way.
code_warn="$(strip_comments "$XREVIEW" | grep -oE 'XREVIEW_THREAD_WARN:-[0-9]+' | grep -oE '[0-9]+' | sort -u)"
if [ "$code_warn" = "8" ] && grep -qi 'answered eight' "$SKILL"; then
  _pass "the documented staleness threshold matches the code ($code_warn)"
else
  _fail "the documented staleness threshold matches the code" "code=$code_warn"
fi

# --reset dropping the thread is the mechanism behind the rotation advice. If the code
# stops doing it, the skill's instruction becomes a no-op that still reads as done.
if strip_comments "$XREVIEW" | grep -q 'rm -f "\$f" "\$(state_dir)/thread"'; then
  _pass "--reset drops the cached thread in the code"
else
  _fail "--reset drops the cached thread in the code" "reset no longer clears the thread"
fi
if grep -q 'drops the cached thread' "$SKILL"; then
  _pass "the skill says --reset drops the thread"
else
  _fail "the skill says --reset drops the thread" "not documented"
fi

# The tier gate only helps if the skill tells the model to pass --expect; the CLI
# accepting a flag nobody sends changes nothing.
if grep -E '^\s*(NONCE=)?\$?\(?xreview dispatch' "$SKILL" | grep -q -- '--expect'; then
  _pass "the skill's dispatch example passes --expect"
else
  _fail "the skill's dispatch example passes --expect" \
        "$(grep -E 'xreview dispatch' "$SKILL" | head -1)"
fi
for sub in '--expect)' 'cmd_tier'; do
  if strip_comments "$XREVIEW" | grep -q -- "$sub"; then
    _pass "the CLI implements $sub"
  else
    _fail "the CLI implements $sub" "absent from the CLI"
  fi
done
# Every tier the skill names must be one the reviewer could actually be set to; a table
# citing a retired model teaches a refusal that can never be satisfied.
# Match any gpt-<ver>-<name>/<effort>, not just the current family: a regex pinned to
# 5.6 stops matching the moment the table names a different version, and an assertion
# that skips the value it was written to check reports green for the wrong reason.
for m in $(grep -oE 'gpt-[0-9]+\.[0-9]+-[a-z]+/[a-z]+' "$SKILL" | sort -u); do
  case "$m" in
    gpt-5.6-sol/xhigh|gpt-5.6-terra/high) _pass "the skill's tier $m is a known setting" ;;
    *) _fail "the skill's tier $m is a known setting" "unrecognised tier in the table" ;;
  esac
done

# The table is the policy. If the skill stops naming a checkpoint, the tier for it
# becomes a judgement call again — which is the failure mode the table exists to remove.
for cp in "Spec sign-off" "plan review" "final whole-branch review"; do
  if grep -qi "$cp" "$SKILL"; then
    _pass "the tier table still covers: $cp"
  else
    _fail "the tier table still covers: $cp" "checkpoint dropped from the skill"
  fi
done
# receipts --tiers is what makes a lazy recommendation visible; the skill has to send
# the reader to it, since --expect cannot detect one.
if grep -q -- 'receipts --tiers' "$SKILL" && strip_comments "$XREVIEW" | grep -q -- '--tiers'; then
  _pass "the skill points at receipts --tiers and the CLI implements it"
else
  _fail "the skill points at receipts --tiers and the CLI implements it" "skill/CLI mismatch"
fi

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
