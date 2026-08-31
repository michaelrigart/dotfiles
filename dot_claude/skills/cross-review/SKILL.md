---
name: cross-review
description: Dispatch a cold, independent review to the paired Codex session and reconcile the findings. Use at spec sign-off, plan completion, and before merging.
---

# Cross-review

Michael's workflow pairs Claude (driver) with Codex (independent reviewer). This skill
automates the relay so that he is not the transport.

## When

Three checkpoints, and only these:

1. A spec is ready for sign-off.
2. A plan is ready to execute.
3. A branch is ready to merge.

Not every turn, and never for reassurance.

## The cold-ask rule

Send the artifact and the constraints. **Never send your reasoning, your transcript, or
your derivation.**

This is not tidiness. A reviewer that has read your reasoning checks whether your
conclusion follows from it, instead of asking whether the framing was right. Its
agreement then carries no information — and the case where you most need a second opinion
is exactly the case where your reasoning is coherent *and wrong*.

A dispatch carries:

- the artifact — a path, or the diff's base and head
- the constraints it must satisfy
- alternatives already rejected, **named without their reasons**: naming them stops the
  reviewer re-raising settled ground, withholding the reasons keeps its evaluation
  independent
- the response shape wanted — file, line, concrete failure scenario

## Dispatching

```
NONCE=$(xreview dispatch <body-file>)
xreview collect "$NONCE" [budget-secs]
```

`xreview` wraps outbound packets in `<from-claude-code>` and returns the reviewer's
answer. It applies provenance itself, because Michael is no longer in the channel to
apply it by hand.

The thread resolves automatically: the Codex pane whose cwd is this repository, cached
under `$XDG_STATE_HOME/xreview/` and re-validated against the live pane every time — a
recorded id proves a thread existed, not that anything is running to answer on it.
`xreview thread` shows what would be used; `xreview init <id>` pins one by hand.

**A freshly built pane has no thread until its first turn.** If dispatch reports that,
send the pane one message and retry — it is not a missing pane.

A timeout is **ambiguous, never retried** — report it and stop.

## Acting on findings

Verify every claim against the code or the artifact before touching anything. Never act
on the reviewer's assertion alone.

- **Verified, and no trade-off involved** — fix it, and say that you did.
- **Design judgement, or a trade-off** — Michael decides. This is most spec and plan
  findings.
- **You disagree, or cannot verify it** — Michael decides.

One round. Remaining disagreement goes to Michael; it does not become another exchange.

## Consultation is not review

When stuck and wanting a second opinion, ask **cold as well**: the problem, the
constraints, what "done" looks like — not your derivation.

You cannot reliably tell "stuck on something hard" from "stuck because I am wrong"; they
feel identical from the inside. Send reasoning only *after* the reviewer has formed its
own view, and only to stop it retreading something genuinely ruled out.

A consultation is not evidence. If the reviewer has seen your reasoning, never present
its agreement as independent confirmation.

## Reporting

Mark which words are the reviewer's. Do not blend its findings into your own prose — that
is the one hop no mechanism covers.

Ping when the **artifact** is done, not at every checkpoint. Interrupt early only when
something genuinely needs Michael's judgement. `xreview notify <msg>` raises a desktop
notification from the shell, so the ping does not depend on remembering to send one.

## What is enforced rather than trusted

`xreview collect` writes a receipt to `$XDG_STATE_HOME/xreview/<repo>/reviews.jsonl`,
and a `PreToolUse` guard denies `glab mr create` / `gh pr create` on a branch with no
receipt. That is the one part of this workflow prose cannot guarantee: a skipped review
is otherwise indistinguishable from one that found nothing.

The guard is deliberately narrow — local merges, pushes, forge web UIs and other CLIs
fail open, and `XREVIEW_GUARD=off` bypasses it. A guard that never fires spuriously is
worth more than a broad one that gets switched off. `xreview receipts` lists what is on
record.
