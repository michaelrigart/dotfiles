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
IMPL=("$XREVIEW" "$ROOT/dot_claude/executable_xreview-guard.sh" "$ROOT/dot_claude/xreview-guard.py"
      "$ROOT/dot_claude/xreview-ledger.py" "$ROOT/dot_claude/executable_xreview-apply-guard.sh")
for _f in "$SKILL" "${IMPL[@]}"; do
  [ -f "$_f" ] || { echo "missing file under test: $_f" >&2; exit 2; }
done
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
  if grep -qE "^[[:space:]]*${sub}\)" <<<"$dispatch"; then
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
# Captured once: every later check against $XREVIEW's stripped code greps this variable,
# never `strip_comments "$XREVIEW" | grep -q ...` directly. A `-q` that matches early
# closes its end of a live pipe, and the producer (strip_comments' own internal
# grep-hv|sed pipe) can then die of SIGPIPE before it finishes - with pipefail set, that
# 141 can outrank grep's 0 and read as a failed check even though the match was real
# (same hazard code_of()'s own comment above describes for the multi-file case).
xreview_code="$(strip_comments "$XREVIEW")"
vars="$(grep -oiE 'XREVIEW_[A-Za-z0-9_]+' "$SKILL" | sort -u)"
[ -n "$vars" ] || _fail "SKILL.md still names the environment knobs" \
  "found none — either the skill stopped documenting them, or this extractor broke"
for var in $vars; do
  # `${VAR` — an expansion, not a mention. The guard's own error text says
  # "Set XREVIEW_GUARD=off to bypass deliberately", so a substring search is satisfied by
  # the message describing the feature after the code implementing it has gone.
  # Not -q: it would exit the moment it finds the match and close the pipe, and with
  # pipefail set, the multi-file code_of() upstream can then die of SIGPIPE before it
  # finishes writing — that 141 outranks grep's own 0 and the whole `if` reads as failed
  # even though the match was real. Reading to EOF costs nothing here and can't race.
  if code_of | grep -E -- "\\\$\\{$var[:}]" >/dev/null; then
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
# The gate is the shell front, the Python grammar beside it, and the ledger it decides with.
GUARD="$ROOT/dot_claude/executable_xreview-guard.sh"
guard_code="$(strip_comments "$GUARD" "$ROOT/dot_claude/xreview-guard.py" "$ROOT/dot_claude/xreview-ledger.py")"
gated="$(grep -oE '(glab|gh)[[:space:]]+(mr|pr)[[:space:]]+(create|new|merge|accept)[A-Za-z0-9_-]*' "$SKILL" | tr -s ' \t' ' ' | sort -u)"
if [ -z "$gated" ]; then
  _fail "SKILL.md still names the gated forge commands" \
        "found none — either the skill stopped documenting the gate, or this extractor broke"
else
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    # The words in order, with whatever the guard puts between them. Pinning one
    # spelling asserts the implementation rather than the gate: this check used to
    # require the literal glob `glab*mr*create`, and so went red when that glob was
    # replaced — correctly — by a command-position regex that gates strictly more
    # precisely. Whether the gate actually fires is xreview-guard.test.sh's job; this
    # one only catches the skill naming a verb the guard stopped looking for at all.
    pat="$(printf '%s' "$c" | sed 's/ /.*/g')"
    if grep -qE -- "$pat" <<<"$guard_code"; then
      _pass "SKILL.md says '$c' is gated, and the guard matches it"
    else
      _fail "SKILL.md says '$c' is gated, and the guard matches it" \
            "no '$pat' match in the guard — the skill promises a gate the guard no longer applies"
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
  aguard_arms="$(strip_comments "$AGUARD" | grep -E 'case[[:space:]]+"\$tool"')"
  for tool in $confined; do
    # The dispatching case only: a `supported="Edit|Write"` string kept for diagnostics
    # is not an arm, and matching it would let a tool fall out of the guard unnoticed.
    if grep -qE "[|( ]$tool[|) ]" <<<"$aguard_arms"; then
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
dispatch_lines="$(grep -E '^\s*(NONCE=)?\$?\(?xreview dispatch' "$SKILL")"
# Assert on the dispatch line itself, not on the file: --diff is mentioned in the prose
# too, so a file-wide grep stays green even after the example reverts to the costly form.
if grep -q -- '--diff' <<<"$dispatch_lines"; then
  _pass "the skill's dispatch example passes the diff inline"
else
  _fail "the skill's dispatch example passes the diff inline" \
        "$(grep -E 'xreview dispatch' "$SKILL" | head -1)"
fi
if grep -q -- '--diff)' <<<"$xreview_code"; then
  _pass "the CLI actually accepts --diff"
else
  _fail "the CLI actually accepts --diff" "no --diff case in the dispatch parser"
fi

# The checkpoint is what the pre-merge gate reads. A dispatch example without it teaches
# a call the CLI refuses, and the model follows the skill, not the usage line.
if grep -q -- '--checkpoint' <<<"$dispatch_lines"; then
  _pass "the skill's dispatch example names the checkpoint"
else
  _fail "the skill's dispatch example names the checkpoint" "$(grep -E 'xreview dispatch' "$SKILL" | head -1)"
fi
if grep -q -- '--checkpoint)' <<<"$xreview_code"; then
  _pass "the CLI actually accepts --checkpoint"
else
  _fail "the CLI actually accepts --checkpoint" "no --checkpoint case in the dispatch parser"
fi
for cp in spec plan pre-merge; do
  if grep -q -- "\`$cp\`" "$SKILL" && grep -qE "(^|[|[:space:]])$cp([|)]|$)" <<<"$xreview_code"; then
    _pass "the skill and the CLI agree on the '$cp' checkpoint"
  else
    _fail "the skill and the CLI agree on the '$cp' checkpoint" "named in one and not the other"
  fi
done
# The gate the skill describes is the gate the guard applies.
if grep -q 'pre-merge' <<<"$guard_code" && grep -q 'approve' <<<"$guard_code" \
   && grep -qi 'latest full-range .pre-merge. review of exactly that change' "$SKILL"; then
  _pass "the skill and the guard agree: only an approved pre-merge receipt opens the gate"
else
  _fail "the skill and the guard agree: only an approved pre-merge receipt opens the gate" "skill/guard mismatch"
fi

# spec 2026-10-02 §3.7: the gate opens only for the full range of the change a review saw,
# a forge merge is pinned and immediate, creation names its destination, and a fix round
# needs a fresh full-range round. A skill that drifts from these teaches a call the gate
# denies, and the guard must read every flag the skill tells the model to pass.
for phrase in 'full range against the branch it will land on' '<dest>...<branch>' \
              'names its destination explicitly' 'never deferred' '--auto-merge=false' \
              '--sha <head>' '--match-head-commit <head>' 'fresh full-range round' \
              '--diff <repo-path>:<range>' 'xreview/ledgers/' '--head <branch>'; do
  if grep -qF -- "$phrase" "$SKILL"; then
    _pass "the skill says '$phrase'"
  else _fail "the skill says '$phrase'" "missing"; fi
done
for flag in '"--auto-merge"' '"--sha"' '"--match-head-commit"' '"--target-branch"' '"--base"' '"--head"'; do
  if grep -qF -- "$flag" <<<"$guard_code"; then
    _pass "the guard reads $flag"
  else _fail "the guard reads $flag" "the skill names a flag the guard never reads"; fi
done
for stale in 'advisory about freshness' '`glab mr create` / `gh pr create` in command position' \
             'local merges, pushes, forge web UIs'; do
  if grep -qiF -- "$stale" "$GUARD" "$ROOT/dot_claude/xreview-guard.py" "$SKILL"; then
    _fail "no '$stale' survives" "still present"
  else _pass "no '$stale' survives"; fi
done

# A schema miss is its own exit code. The skill must say what to do with it, or the model
# treats raw reviewer prose as findings.
if grep -q 'Exit 4' "$SKILL" && grep -q 'exit 4' <<<"$xreview_code"; then
  _pass "the skill and the CLI agree that a schema miss exits 4"
else
  _fail "the skill and the CLI agree that a schema miss exits 4" "skill/CLI mismatch"
fi

# --reset dropping the thread is the mechanism behind the rotation advice. If the code
# stops doing it, the skill's instruction becomes a no-op that still reads as done.
if grep -q 'rm -f "\$f" "\$(state_dir)/review-thread"' <<<"$xreview_code"; then
  _pass "--reset drops the cached thread in the code"
else
  _fail "--reset drops the cached thread in the code" "reset no longer clears the thread"
fi
if grep -q 'drops the cached thread' "$SKILL"; then
  _pass "the skill says --reset drops the thread"
else
  _fail "the skill says --reset drops the thread" "not documented"
fi

# No tier gate, on either side. The removed --expect refused a dispatch whenever the
# pane's model name was not in a hard-coded table, so every new model release blocked
# every review. The skill must not reintroduce it by example, and the CLI must not carry
# a flag that quietly does nothing.
if grep -q -- '--expect' <<<"$dispatch_lines"; then
  _fail "the skill's dispatch example is free of --expect" \
        "$(grep -E 'xreview dispatch' "$SKILL" | head -1)"
else
  _pass "the skill's dispatch example is free of --expect"
fi
if grep -q -- '--expect' "$XREVIEW"; then
  _fail "the CLI has no --expect flag" "still present in the CLI"
else
  _pass "the CLI has no --expect flag"
fi
# A skill naming a specific model teaches exactly the gate that was removed — the reader
# compares the pane against the name and reports a mismatch by hand. Nothing in the CLI
# can stop that, so it is asserted here instead.
reviewer_tiers="$(grep -oE 'gpt-[0-9]+\.[0-9]+-[a-z]+/[a-z]+' "$SKILL")"
if grep -q . <<<"$reviewer_tiers"; then
  _fail "the skill names no specific reviewer tier" \
        "$(grep -oE 'gpt-[0-9]+\.[0-9]+-[a-z]+/[a-z]+' "$SKILL" | sort -u | tr '\n' ' ')"
else
  _pass "the skill names no specific reviewer tier"
fi
if grep -qi 'never gate a dispatch on which model' "$SKILL"; then
  _pass "the skill says the tier is not a gate"
else
  _fail "the skill says the tier is not a gate" "the prohibition is gone"
fi

# Reporting survives the gate's removal: tier and receipts --tiers stay, because knowing
# what reviews ran at is still worth having — it just must not block anything.
for sub in 'cmd_tier' '--tiers'; do
  if grep -q -- "$sub" <<<"$xreview_code"; then
    _pass "the CLI still implements $sub"
  else
    _fail "the CLI still implements $sub" "absent from the CLI"
  fi
done
if grep -q -- 'receipts --tiers' "$SKILL"; then
  _pass "the skill still points at receipts --tiers"
else
  _fail "the skill still points at receipts --tiers" "skill/CLI mismatch"
fi

# A collect that runs out of budget while the turn is still on record is not a timeout.
# Telling the model otherwise is what turned long reviews into escalations.
if grep -q 'Exit 3' "$SKILL" && grep -q 'exit 3' <<<"$xreview_code"; then
  _pass "the skill and the CLI agree that a still-running turn exits 3"
else
  _fail "the skill and the CLI agree that a still-running turn exits 3" "skill/CLI mismatch"
fi
if grep -qi 'resumes the wait' "$SKILL"; then
  _pass "the skill says collecting again is safe"
else
  _fail "the skill says collecting again is safe" "the model will stop waiting too early"
fi

# Rotation is keyed to checkpoints, not rounds. Observed 2026-09-09: a review stopped at
# round 4 of one checkpoint and escalated, on the reasoning that the thread had "answered
# three rounds" and was no longer cold — conflating the branch round counter with the
# thread staleness count, and reading "cold" (what you send) as "fresh thread per round".
# All three confusions are cheap to assert against and expensive to hit.
if grep -qi 'stay on the same thread' "$SKILL"; then
  _pass "the skill says rounds within a checkpoint keep one thread"
else
  _fail "the skill says rounds within a checkpoint keep one thread" \
        "nothing stops a round count being read as staleness"
fi
# Rotation is now mechanical: each checkpoint starts on a fresh thread by itself. The old
# staleness warning and "start a fresh Codex session by hand" advice must not survive in the
# skill, or the model rotates threads that the workflow already rotates.
if grep -qi 'Staleness is mechanical' "$SKILL"; then
  _pass "the skill says staleness is mechanical"
else
  _fail "the skill says staleness is mechanical" "staleness looks like a judgement call again"
fi
for stale in 'XREVIEW_THREAD_WARN' 'answered eight' 'send the pane one message' 'Start a fresh Codex session' 'codex queue'; do
  if grep -qi -- "$stale" "$SKILL"; then
    _fail "the skill no longer says '$stale'" "still present"
  else
    _pass "the skill no longer says '$stale'"
  fi
done
# fix round 2/E: the ordering is quit-then-turn-then-resume, not "turn starts first" (which
# omitted the pane-quit step entirely and drifted from spec 7.3 as amended in d9d31a4).
if grep -qi "the pane's old session is quit first" "$SKILL"; then
  _pass "the skill explains the quit-then-turn-then-resume ordering"
else
  _fail "the skill explains the quit-then-turn-then-resume ordering" "missing"
fi
if grep -q 'The turn starts first' "$SKILL"; then
  _fail "the skill no longer says the turn starts first" \
        "stale wording survives - it omits the pane being quit before the turn"
else
  _pass "the skill no longer says the turn starts first"
fi
if grep -q 'The pane comes first' "$SKILL"; then
  _fail "the skill no longer says the pane comes first" "stale pane-first wording survives"
else
  _pass "the skill no longer says the pane comes first"
fi
# A pane that cannot be pointed at the thread is a warning, not a refusal (item 16): the
# review still runs and collect still works. If this drifts back to a refusal, the model
# would stop a review that the daemon is still happily running.
if grep -qi 'only warns' "$SKILL" && grep -qi 'review still runs' "$SKILL"; then
  _pass "the skill says a pane that cannot be pointed at the thread only warns"
else
  _fail "the skill says a pane that cannot be pointed at the thread only warns" "missing"
fi
# Restarting a contaminated daemon disconnects every Codex TUI. That is Michael's call.
if grep -q 'codex-daemon restart' "$SKILL" && grep -qi "Michael's call" "$SKILL"; then
  _pass "the skill leaves the daemon restart to Michael"
else
  _fail "the skill leaves the daemon restart to Michael" "missing"
fi
# "Cold" is about what you send, not about the thread. The escalation list is exhaustive.
if grep -qi 'Cold describes what you' "$SKILL"; then
  _pass "the skill disambiguates 'cold'"
else
  _fail "the skill disambiguates 'cold'" "the two senses can be swapped again"
fi
if grep -qi 'list is exhaustive' "$SKILL"; then
  _pass "the skill closes the escalation list"
else
  _fail "the skill closes the escalation list" "a new escalation reason can be invented"
fi

# "XREVIEW_PANE picks one" read as licence for the model to choose among several Codex
# panes. Only Michael may.
if grep -q 'picks one' "$SKILL"; then
  _fail "the skill no longer reads as licence to pick a pane" \
        "'picks one' still present"
else
  _pass "the skill no longer reads as licence to pick a pane"
fi
if grep -qi "Michael can set .XREVIEW_PANE. to one of them" "$SKILL"; then
  _pass "the skill says Michael sets XREVIEW_PANE, not the model"
else
  _fail "the skill says Michael sets XREVIEW_PANE, not the model" "missing"
fi

# Policy 6 (spec 2026-09-30): a trade-off inside the approved spec is the agent's to rule
# on and record under "Rulings" in the MR; only what would change the spec goes to Michael.
if grep -q 'Rulings' "$SKILL" && grep -qi 'would change the approved spec' "$SKILL"; then
  _pass "the skill routes in-spec trade-offs to a recorded ruling"
else
  _fail "the skill routes in-spec trade-offs to a recorded ruling" "every trade-off still goes to Michael"
fi

# The escalation list must actually be exhaustive: refusals only Michael can resolve
# (no pane, several panes, the daemon down and staying down) belong on it, not just in
# the "dispatch refuses" prose above it.
esc="$(sed -n '/^Escalate to Michael when/,/^That list is exhaustive/p' "$SKILL")"
if grep -qi 'no Codex pane' <<<"$esc"; then
  _pass "the escalation list names the no-pane/several-panes refusal"
else
  _fail "the escalation list names the no-pane/several-panes refusal" "missing from the list"
fi
if grep -qi 'down and will not start' <<<"$esc"; then
  _pass "the escalation list names the daemon-will-not-start refusal"
else
  _fail "the escalation list names the daemon-will-not-start refusal" "missing from the list"
fi
# item 16 fix round 1/C1: the pane is freed BEFORE the turn exists, and that free can now
# itself refuse (the pane closes, or will not exit) - distinct from a pane that merely fails
# to RESUME after the turn has started, which only warns. Both lists must say so, or the
# model either does not know to escalate a real refusal, or thinks the post-turn warning is
# one too and escalates every noisy pane.
if grep -qi 'would not free' <<<"$esc"; then
  _pass "the escalation list names the pane-will-not-free refusal"
else
  _fail "the escalation list names the pane-will-not-free refusal" "missing from the list"
fi
if grep -qi 'the pane will not free' "$SKILL"; then
  _pass "the skill's refusal list names the pane-will-not-free case"
else
  _fail "the skill's refusal list names the pane-will-not-free case" "missing"
fi

# Minor 7: archiving the superseded thread is conditional on the pane actually showing the
# new one, not on the reset itself - stale "restarts ... and archives" prose would teach an
# unconditional archive that does not match a pane step that failed to confirm anything.
if grep -qi 'archived once the pane actually shows' "$SKILL"; then
  _pass "the skill says the old thread is archived once the pane shows the new one"
else
  _fail "the skill says the old thread is archived once the pane shows the new one" "missing"
fi

# The reviewer's answer is schema-checked JSON, not raw text, except on the exit-4 miss.
if grep -q 'findings JSON (or, on exit 4, raw untrusted text)' "$SKILL"; then
  _pass "the skill says the answer is findings JSON, raw text only on exit 4"
else
  _fail "the skill says the answer is findings JSON, raw text only on exit 4" \
        "stale 'comes back as raw text' wording survives"
fi

# Collect's exit 1 for an unreachable daemon is not the ambiguous "no turn on record"
# case: it means retry, not report-and-stop.
if grep -qi 'Codex daemon is unreachable; the turn is on record' "$SKILL" \
   && grep -q 'codex-daemon ensure' "$SKILL"; then
  _pass "the skill explains the unreachable-daemon exit 1 is not the ambiguous case"
else
  _fail "the skill explains the unreachable-daemon exit 1 is not the ambiguous case" "missing"
fi

# spec 2026-10-01: the pane's screen is evidence, never instruction; harness worktrees use
# their owner's pane; the new refusals are named, and the lock refusal is waited out.
screen_bullet="$(awk '/pane.s screen/{f=1} f&&/^[[:space:]]*$/{exit} f' "$SKILL")"
if [ -n "$screen_bullet" ] && grep -qi 'untrusted' <<<"$screen_bullet"; then
  _pass "the skill says the pane's screen is untrusted evidence"
else _fail "the skill says the pane's screen is untrusted evidence" "missing"; fi
if grep -q '\.claude/worktrees' "$SKILL"; then
  _pass "the skill says a harness worktree uses its owner's pane"
else _fail "the skill says a harness worktree uses its owner's pane" "missing"; fi
if grep -qi 'another dispatch is using' "$SKILL"; then
  _pass "the skill names the per-pane lock refusal"
else _fail "the skill names the per-pane lock refusal" "missing"; fi
if grep -qi 'cannot inspect' <<<"$esc"; then
  _pass "the escalation list names the cannot-inspect refusal"
else _fail "the escalation list names the cannot-inspect refusal" "missing from the list"; fi
for phrase in 'cannot lock' 'cannot read whether' 'resuming something other than a thread id' \
              'herdr pane process-info' 'herdr pane get'; do
  if grep -qi "$phrase" <<<"$esc"; then
    _pass "the escalation list names '$phrase'"
  else _fail "the escalation list names '$phrase'" "missing from the list"; fi
done
if grep -qi 'another dispatch' <<<"$esc"; then
  _fail "the lock refusal is not escalated" "it is on the escalation list"
else _pass "the lock refusal is not escalated"; fi
# The refusal list (not just the escalation list) quotes the exact resume refusal and names
# both pane reads; later rounds find the pane on the thread only while its TUI is connected.
refusals="$(sed -n '/^Dispatch refuses, before/,/^Only the "no turn on record"/p' "$SKILL")"
for phrase in 'is resuming something other than a thread id' 'herdr pane process-info' 'herdr pane get' \
              'cannot read the Codex pane'; do
  if grep -qF "$phrase" <<<"$refusals"; then
    _pass "the refusal list quotes '$phrase'"
  else _fail "the refusal list quotes '$phrase'" "missing from the list"; fi
done
if grep -q 'still connected to the' "$SKILL" && grep -q 'otherwise it is resumed again' "$SKILL"; then
  _pass "the skill says a later round keeps the pane only while its TUI is connected"
else _fail "the skill says a later round keeps the pane only while its TUI is connected" "missing"; fi
if grep -q '300000' "$SKILL"; then
  _pass "the skill gives dispatch a five-minute tool timeout"
else _fail "the skill gives dispatch a five-minute tool timeout" "missing"; fi

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
