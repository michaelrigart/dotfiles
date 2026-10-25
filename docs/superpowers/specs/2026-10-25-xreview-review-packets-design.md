# Review packets that fit the reviewer

**Status:** Implemented
**Date:** 2026-10-25
**Scope:** `dot_local/bin/executable_xreview` (dispatch and collect), a new packet builder
`dot_claude/xreview-packet.py`, `dot_claude/xreview-ledger.py` (the gate's decision),
`dot_local/bin/executable_xreview-rpc` (thread fork, the turn's compaction flag),
`dot_config/xreview/` (reviewer instructions, findings schema, a new switch file), the
cross-review skill, a replay harness in `.scripts/`, and their test suites.

## 1. Problem

Measured on 2026-10-25 over 556 review turns (2026-09-01 to 2026-10-25). These are the turn
records in `~/.local/state/xreview/*/turns/` whose Codex rollout, in `~/.codex/sessions` or
`~/.codex/archived_sessions`, was still plain `.jsonl`: 556 of 1,280. Codex compresses
older rollouts to `.jsonl.zst`, and those were not read. The figures below describe that
sample, not every review.

**Michael is prompted to raise the size cap.** `xreview dispatch` refuses a packet whose diffs
exceed 100 KB (`XREVIEW_MAX_DIFF_BYTES`). Packets run p50 74 KB, p75 117 KB, p90 282 KB, max
992 KB; 174 of 555 turns were over 100 KB. A session cannot raise the cap: an environment
assignment in front of `xreview` takes it out of `sandbox.excludedCommands`. So every
oversized review becomes a `! XREVIEW_MAX_DIFF_BYTES=… xreview dispatch …` handed to
Michael: 34 distinct refusals in the Claude transcripts, overrides from 150 KB to 1.2 MB.

**Inline diffs are right.** A round-1 review with the diff inline takes median 0.33M input
tokens and 3 tool calls. Pointing the reviewer at paths took ~2.0M tokens and ~16 steps
(measured 2026-09-01). This design keeps the diff inline whenever it fits.

**Re-sending the full diff every round overflows the reviewer.** Rounds of a checkpoint stay
on one thread, and each round sends the whole diff again. So the thread holds every earlier
version of the same hunks. Context at the first step of a turn, median by round: 47k, 99k,
132k, 159k, 180k, then 199k from round 6 on, against a 258,400-token window. **48 of 556
turns (9%) compacted mid-review:** Codex summarised its own context, including part of the
change under review, and still returned a verdict. Compaction fired at about 244k input
tokens. The compacted turns had packets over 150 KB or were round 3 and later, with
exceptions. Their verdicts opened the pre-merge gate like any other.

**Compaction does not empty the context.** Every one of the 48 compactions kept the most
recent user messages verbatim: 275–295 KB of earlier review packets, possibly cut off
partway. The next model step started at p50 100k, max 123k tokens. Compacting on purpose would
leave the same stale text, so this design never compacts. It starts a fresh thread instead.

**Plans fill pre-merge packets.** Bytes of pre-merge diffs: code 52.8%, tests 26.5%,
`docs/superpowers/plans/` 15.1%, other design records 4.6%, lock and generated files 1.1%.
Plans were already reviewed at their own checkpoint.

Calibration used below, from the same data: a packet costs about 1 token per 3.58 bytes. A
fresh review thread starts at about 27k tokens before the packet (system prompt, tools,
repository instructions). A turn grows its context by p50 5.5k, p90 29k, p99 56k, max 71k
tokens while it investigates.

## 2. Goals, non-goals, anti-goals

Goals:

- Michael is never asked to start or resize a review.
- Every review turn holds the part of the change it is judging in full, without
  compaction, and the gate opens only on such reviews.
- Fewer tokens per round once a review is under way.
- No change ships that lowers review quality. That is measured (§5), not argued.

Non-goals:

- No change to the checkpoints, the cold-ask rule, the dispatch command line, the pane
  lifecycle or the tier policy. Claude still dispatches every round with the full range
  (`--diff <dest>...<branch>`). Which packet that range becomes is xreview's choice.
- No headless `codex exec` reviews; the live Codex view stays.
- No change to what the gate binds: the fingerprint of the full range, per destination.

Anti-goals, which would be failures even if everything else worked:

- A review that saw only part of the change opening the gate.
- A quality loss accepted in exchange for tokens.
- A new prompt or escalation for Michael in normal operation.

## 3. Design

### 3.1 Packet kinds and framing

xreview builds every packet through `xreview-packet.py`. It lives in `~/.claude` beside the
ledger, so neither xreview nor the gate runs code from a directory the sandbox can write. The
replay harness (§5) imports the same module, so the packets it tests are the ones dispatch
sends. Each target of a dispatch gets one of:

- **full**: the whole `base..tip` patch, rendered by the ledger with its diff flags, as today.
- **delta**: the patch from the tip the previous round reviewed to the new tip (§3.4).
- **slice**: part of a full packet, when even a fresh thread cannot hold all of it (§3.3).

**Framing** is what every packet gains when the `framing` switch is on (§3.8). Delta, slices
and the coverage check all need it.

- **File list.** The packet opens with each changed path and its +/− counts. Each path is
  marked *shown* (its patch is in this packet), *earlier* (delta: shown in an earlier round),
  *elsewhere* (slice: shown in another slice) or *listed* (a plan covered by its plan
  review, §3.5). A file split into parts (§3.3) has one line per part.
- **Target labels.** With several targets, a path carries its target's label
  (`<repo-path>:`), as `--diff` named it.
- **`reviewed_files`** in the findings schema (§3.6).
- **Instructions** for both in `reviewer.md`.

### 3.2 Fit check

Before a turn starts, xreview estimates whether it fits:

    need  = context now + ceil(packet bytes / 3.5) + reserve
    limit = 0.9 × the model's context window

- **Context now**: for an existing thread, input plus output of the latest `token_count`
  record in its rollout (`last_token_usage`); for a fresh thread, 30,000 (measured ~27k).
- **The window**: `model_context_window` from the thread's latest `task_started` record. A
  fresh thread uses the most recent value from this repository's review threads, else from
  any rollout. If none can be read, dispatch refuses before touching the pane. That is a
  local failure for the skill to report, not a size question.
- **Reserve**: 60,000 tokens of working room (p99 growth within a turn is 56k).
- 0.9 keeps the turn under Codex's own compaction point (seen at ~94% of the window).

Then, in order:

1. Use a delta if the target qualifies (§3.4), otherwise a full packet. A pre-merge target
   lists the plans an approved plan review covered (§3.5).
2. If `need ≤ limit` on the checkpoint's thread, send it there.
3. Otherwise, **move the checkpoint to a fresh thread.** A delta needs the old thread, so the
   packet is rebuilt as full, and the fit is checked again with fresh-thread context.
   - Moving works as at a checkpoint's first dispatch: the fresh thread becomes the
     checkpoint's thread, and the pane is resumed onto it.
   - The old thread joins the superseded list and is archived once the pane shows the new
     one, as `round --reset` does today.
   - The round counter carries on. This is not a new checkpoint.
4. If a full packet does not fit even a fresh thread, slice it (§3.3).

Step 3 replaces what happens today. Today the same overflow makes Codex compact in the middle
of the turn and review from its own summary. A fresh thread holds the whole packet instead.
The reviewer loses its memory of earlier rounds. The body's existing list of settled points
(alternatives already rejected, named without reasons) is what stops it from re-raising them.

With the fit check on, `XREVIEW_MAX_DIFF_BYTES` no longer applies, and no size is refused.

### 3.3 Slices

A full packet too large for a fresh thread (more than ~500 KB at today's window) is split
into slices. Each slice is a group of review units, packed in path order, with each slice's
`need` at or under `limit` on a fresh thread.

- **Review units.** A unit is normally one whole file's patch. A file whose patch alone
  exceeds a slice is split into **parts**, each with the file's `diff --git` header:
  - groups of whole hunks;
  - a single hunk larger than a slice is split into consecutive line ranges, each with a
    corrected `@@` header;
  - a single line larger than a slice (minified or generated content) is split into byte
    ranges at UTF-8 character boundaries. Each range is a part that names its line and its
    bytes (`line N, bytes a–b of c`).

  Each part is labelled `<path>#<i>/<n>` and is a unit of its own. Every split ends at a
  bounded size, so every unit fits a fresh thread, and the reviewer never fetches a patch
  itself.
- **Content.** Each slice turn carries the complete file list and its own units, plus a line
  saying the other slices are reviewed in their own turns and any file may be opened. The
  file list is bounded too. If the complete list would take more than a tenth of a slice, a
  slice carries only its own units' lines, plus the total count of files and the command
  that lists them all.
- **Coverage.** Each part's label is its own coverage entry (§3.6).

Every slice runs on a **fresh thread of its own**, one after another, and the pane follows
each.

- `dispatch` starts slice 1 exactly as it starts any review on a fresh thread, and prints the
  nonce.
- `collect` waits for each slice. Then, under the pane lock, it starts the next slice's
  thread and turn, and resumes the pane onto it. The pane steps are dispatch's own, moved into
  shared functions. So the existing rules hold: keystrokes only while no turn is running on
  the pane's thread, and a pane that fails to follow only warns.
- `collect` keeps its state in `turns/<nonce>.slices`, so exit 3 resumes where it stopped. A
  slice turn-start that is sent but not answered is recovered as dispatch's exit 6 is (the
  turn not there before), never re-sent.
- Slice threads join the superseded list as the pane moves on, and are archived as above.
- `collect` prints one merged answer: `approve` only if every slice approved, all findings,
  and the union of `reviewed_files`.

The last slice's thread becomes the checkpoint's thread. A sliced round never roots a delta
(§3.4), so the next round is full and, at the same size, sliced again.

### 3.4 Delta rounds

A target qualifies for a delta when the previous review on the checkpoint's current thread
has a collected receipt for the same repository and range, and:

- its base equals the new base (no rebase onto a moved destination);
- its tip is an ancestor of the new tip;
- that receipt is clean (§3.6), and so is every receipt back to the chain's root;
- the chain's root, the first receipt of the chain, is a `full` packet on this same thread.
  A sliced round never roots a chain: each slice is on its own thread, so no thread holds the
  whole change;
- **the thread still holds the chain.** Michael can use the review thread in his pane, so
  receipts alone do not prove this. At dispatch, xreview reads the thread's turns
  (`thread/turns/list`):
  - every chain turn, root first, must still be on the thread (no rewind or revert removed
    one);
  - no turn since the root, whether the chain's or anyone's, may carry a compaction;
  - there must be no thread-level compaction since the root (a `/compact` in the TUI).

  The turn ids it checked are recorded in the receipt as `history`.

The packet says, in fixed text, which round it follows, that the change as of that round is
earlier in the thread, and that the change is to be judged as it now stands, including how
the new code meets the old. Then it carries the file list for the whole change and the patch
`prev tip..new tip`. Its receipt records the full range's fingerprint, as every receipt does.
It also records the receipt it follows (`delta_from`). Otherwise the target gets a full
packet.

### 3.5 Plans covered by their plan review

A plan is left out of a pre-merge packet (full, delta or slice) only as far as an approved
plan review covered it. For each path under `docs/superpowers/plans/`:

- **What a plan review proves.** A `plan`-checkpoint receipt records `plan_blobs`: each plan
  path its packet showed **in full**, meaning the path was added within the reviewed range,
  so the patch carried the whole file. Each entry carries the blob id at the tip. A plan that
  existed unchanged in the range, or was only modified in it, is not in `plan_blobs`. Its
  whole content was not in that packet.
- **The binding.** For each plan path, xreview looks for the latest `plan`-checkpoint receipt
  in this repository's ledger that is an `approve`, is clean, and has that path in
  `plan_blobs`. A receipt from before this design has neither field and does not bind. A
  binding needs a plan review dispatched with `--diff` (§4); a plan pasted into the body
  leaves no tip to bind to.
- **If one exists**, the plan is *listed* with the receipt's nonce and blob. Instead of the
  plan's whole patch, the packet shows its patch from that blob to the current content,
  usually a few status and progress lines. A fixed line says the rest was reviewed at the
  plan checkpoint.
- **If none exists**, the plan's whole patch is shown, as today.

So every byte of the plan's current content was either shown whole in an approved plan review
or is in this packet. Specs and every other path are always shown. The fingerprint and the
gate still cover the plans.

`xreview-ledger.py diff` gains a path exclusion plus the per-plan patches. Its header-count
check counts the records it renders, so the "packet matches the change" check still holds.
The receipt records `plans_from`: each listed plan path with the plan receipt and the blob
it was bound to.

### 3.6 Clean turns

A turn is **clean** when both hold:

- **No compaction during the turn**: no `contextCompaction` item in the turn
  (`thread/turns/list`, which xreview-rpc already reads). If the item is not exposed there,
  check for a `compacted` record in the rollout after the turn's `task_started`. This check
  is always made and recorded.
- **Coverage**, with `framing` on: every *shown* path or part label in the packet appears in
  the answer's `reviewed_files`, compared after stripping `a/`, `b/` and `./`. A listed
  plan's shown later patch counts as shown. The reviewer instructions
  ask for each shown file it reviewed, and no file it did not read.

A receipt gains:

- `packet`: `full`, `delta` or `slices`;
- `switches`: the four switch states at dispatch;
- `compacted`;
- `missing`: the uncovered paths or part labels, at most 50;
- `clean`;
- `delta_from` and `history` (§3.4);
- `plans_from`, and on a plan-checkpoint receipt `plan_blobs` (§3.5).

For slices, the receipt is clean only if every slice turn is.

When a turn is not clean, `collect` prints the answer as usual and exits 0. It adds a line on
stderr naming why, and whether the gate stays closed (§3.7). Its findings are acted on as
normal. The next dispatch's packet already reflects the cause: after a compaction, a full
packet on a thread that fits it; after a coverage gap, the packet names the files missed last
round.

### 3.7 The gate

`decide()` still requires the latest review of exactly this change, for this destination, to
be an `approve` receipt. That receipt must now also be **whole**. Whole is judged from the
receipt alone, including the `switches` it recorded at dispatch. The gate never reads
`packets.conf`, so turning a switch on or off never reopens or closes a review already on
record.

- **Old receipts.** A receipt with no `packet` field and none of `switches`, `clean` or
  `compacted` predates this design and is whole, so approvals in flight at rollout still open
  the gate. A receipt that carries any of those three without a `packet` kind is not one xreview
  writes, and is denied.
- **Recorded switches.** A receipt with a `packet` kind must carry `switches` as an object.
  A `delta` or `slices` receipt must have recorded `framing` on, since coverage is what holds
  its reviewer to the files.
- **Coverage.** When the receipt recorded `framing` on, `missing` must be empty.
- **Compaction.**
  - A `delta` or `slices` receipt must not have compacted.
  - A `full` receipt must not have compacted when it recorded `fit` on. With `fit` off, the
    packet's size is the old cap's business, so a compacted full review keeps opening the
    gate as today. Otherwise an oversized review would compact on every retry and never
    pass.
- **The chain**, for `delta`. Each `delta_from` names a receipt in the same ledger, and each
  link must hold:
  - the same thread, repository, destination and base;
  - its tip is where this delta starts;
  - it is clean, under the same rules as above.

  The walk ends at a `full` receipt on that thread. It is iterative, with cycle detection. A
  link may carry a `changes` verdict. The approving receipt's `history` must list every
  chain turn, root first.
- **Plans**, for each entry in `plans_from`: the named receipt is in the same ledger, is a
  `plan`-checkpoint `approve`, is clean, and lists that path with that blob in its
  `plan_blobs`.

xreview only builds valid chains. The gate checks them anyway, because the gate is the part
of this workflow that is enforced rather than trusted.

### 3.8 Switches

`~/.config/xreview/packets.conf` (chezmoi: `dot_config/xreview/packets.conf`) holds four
`key=on|off` lines:

| Switch | Covers | Off |
|---|---|---|
| `framing` | §3.1 framing, the coverage check | today's packet and schema |
| `fit` | §3.2, §3.3 | today's byte cap and `XREVIEW_MAX_DIFF_BYTES` |
| `delta` | §3.4 | every round full |
| `omit_plans` | §3.5 | plans shown |

`fit`, `delta` and `omit_plans` need `framing`. With `framing` off they act as off, and
xreview says so once per dispatch. All four start `off`. Each is turned on only after it
passes the replay (§5). Recording whether a turn compacted (§3.6) is always on. It changes
nothing until a switch makes the gate read it.

## 4. Instructions

- **`reviewer.md`**: the packet kinds and their fixed lines; `reviewed_files` and part
  labels; listed plans.
- **Cross-review skill**:
  - Drop the cap and the advice to slice by hand. xreview picks the packet, and dispatch
    never refuses on size, except on a pinned thread (below).
  - xreview may move a checkpoint to a fresh thread when the current one cannot hold the
    next packet. That is mechanical; the agent still never rotates a thread by judgement.
  - A review that is not clean may keep the gate closed: act on its findings and dispatch the
    next round as usual.
  - Slices take longer, so give `collect` a larger budget.
  - Plan reviews are dispatched with `--diff <dest>...<branch>` once the plan is committed,
    so that pre-merge can bind the plan to its approval (§3.5).
  - The escalation list gains two entries and is otherwise unchanged:
    - a pinned review thread (`xreview init` or `XREVIEW_THREAD`) that cannot hold the next
      packet. The pin is Michael's, so dispatch refuses rather than move the checkpoint off it;
    - with `fit` off, a packet over the size cap. The cap is Michael's to raise, and an agent
      cannot raise it from a session (§1).
- **Memory** `excluded-command-must-lead`: its cap remark is updated once `fit` is on.

## 5. Replay evaluation

`.scripts/xreview-replay.py` measures each switch against today's behaviour on past reviews
before the switch is turned on.

### 5.1 Cases

From the ledgers, turn records and rollouts: past rounds whose findings parse, whose base and
tip commits still exist locally, and that hold at least one known-real finding. Most recent
first, across repositories:

- **`omit_plans`**: up to 10 pre-merge rounds whose plan files bind to an approved plan
  receipt (§3.5). 20 approved plan receipts with targets are on record today. For these
  historical receipts, cleanliness is read from their rollouts, and `plan_blobs` from git:
  the plan paths added within each receipt's range.
- **`framing`**: the `omit_plans` cases, topped up to 10 with other pre-merge rounds. Where a
  case serves both, A and A′ are shared.
- **`delta`**: up to 10 rounds 2 and later, whose previous round was on the same thread with
  the same base.
- **`fit`**, two kinds of case:
  - **Slicing**: round-1 reviews too big for a fresh thread (sliced under §3.3). Seven are on
    record today, so this kind is judged on at most seven cases, with the count reported.
  - **Moving to a fresh thread** (§3.2 step 3): up to 5 rounds 2 and later that would have
    moved, meaning the thread's context plus the packet exceeded `limit`. The 48
    mid-review compactions are drawn from first.

### 5.2 Known-real findings

A historical P0–P2 finding is known-real when the change between that round's tip and the
next round's tip fixed it. A blind judge decides each one, shown the finding and that
interdiff, and answers yes, no or unclear. Only "yes" counts.

### 5.3 Arms

Every arm runs on a fresh thread, unless noted:

- **A and A′**: two runs of today's packet with today's schema. They give the noise between
  identical runs.
- **F**: framing on, every other switch off. It runs on the shared pre-merge cases only.
- **B**: framing plus the one switch under test.

**History.** `delta` cases and `fit`'s fresh-thread cases need the thread as it stood before
round k:

- **Preferred:** the historical review thread is forked (`thread/fork`), and the fork is
  rewound to just before round k. A, A′ and, for `delta`, B each get a fork. For a
  fresh-thread case, B runs on a fresh thread with the full packet.
- **Fallback**, when a historical thread cannot be forked or rewound: rounds 1 to k−1 are
  replayed once on a fresh thread with today's packets, each with the scratch checkout at
  that round's own tip, and the result is forked per arm.

Either way, every turn's working directory is the scratch clone checked out at the tip of
the round that turn reviews, never a later one. It is set per turn, so a forked historical
thread never reads the live checkout it was created in.

### 5.4 Judging

Judges are Claude subagents (`sp-standard`), dispatched by the driving session between the
harness's phases, batched one case per judge:

1. `cases` selects candidates and writes the known-real judge inputs.
2. The session judges them.
3. `run` runs the arms.
4. `match` writes the matching inputs, one per case, with every run under a random label.
5. The session judges them.
6. `report` computes the results.

Matching: for each known-real finding, the judge names the run finding that reports the same
defect, or none. The arm-to-label map stays in the harness's state. Judge inputs never carry
it, and judges are told nothing about the design.

### 5.5 Pass bar

For each switch, on its cases:

- F or B recalls the known-real findings at least as often as the lower of A and A′.
- F or B misses no P0 or P1 that both A and A′ found.
- Any arm with framing: over 10% of runs that approved but failed coverage means fixing the
  path normalisation and re-running those cases before the switch is turned on.

The report also gives tokens and compactions per arm. If `framing` fails, the other switches
stay off as well, and the follow-up is a change to this spec.

### 5.6 Running it

- Turns run through the Codex daemon with `xreview-rpc` primitives, never `xreview dispatch`.
  No pane, ledger or round counter is touched, so the gate cannot be affected.
- Each case gets a scratch `git clone --shared`, checked out at the tip of the round being run
  (§5.3).
- All arms of a case run back to back at the daemon's current model and effort, which is
  recorded.
- At most 3 turns run at once.
- Tokens are tallied from the rollouts, with a hard stop at 60M. Switches run in the order
  `framing` with `omit_plans`, then `delta`, then `fit`. A run that stops early reports what
  it has. A switch whose cases did not all run stays off.
- Every thread it creates is recorded as it is created and archived at the end, and the
  scratch clones are removed.
- `run` needs the daemon socket, so it runs unsandboxed, in the background.
- Expected: about 105 turns plus slices, 55–70M Codex tokens if every case ran, 3–4 hours of
  `run`. So `fit` may be cut off by the 60M stop.
- The judges use Claude subagents, not Codex tokens.

**Results** go in §9 of this spec, with the switch states that follow from them. Raw run
files stay in `~/.local/state/xreview/replay/` and are never committed.

## 6. Testing

- **`tests/xreview-packet.test.sh`** (new), against fixture repositories:
  - framing marks and target labels;
  - delta eligibility, each condition on its own, including a sliced root, a missing chain
    turn, a foreign compacted turn and a thread-level compaction;
  - plan binding:
    - with an approved receipt whose `plan_blobs` has the path, only the plan's later patch
      is shown;
    - with none, an unclean one, or one where the plan was unchanged or only modified in its
      range, the whole plan is shown;
    - the header-count check holds either way;
  - the fit arithmetic at its boundaries;
  - slice packing: a file split by hunks, a single hunk split by lines, and a single line
    split by bytes on a UTF-8 boundary, each with corrected headers and part labels.
- **`tests/xreview.test.sh`**, with `xreview-rpc` and `herdr` stubbed:
  - dispatch picks full, delta, a fresh thread, or slices as the fit says, and moves the pane
    for a fresh thread;
  - with `fit` on there is no size refusal, and with it off there is the old one;
  - collect runs slices on fresh threads, moves the pane between them under its lock, resumes
    after exit 3, recovers an unanswered slice start and merges the answers;
  - the not-clean notice;
  - receipts carry the new fields;
  - with every switch off, the packet is byte-for-byte today's.
- **`tests/xreview-rpc.test.sh`**: `thread-fork` and the turn's compaction flag, against the
  fake server the suite already uses.
- **`tests/xreview-ledger.test.sh`** and **`tests/xreview-guard.test.sh`**:
  - legacy receipts stay whole;
  - each enforcement rule of §3.7, under its recorded switch;
  - chains: valid, broken link, wrong base, unclean link, sliced root, cycle, a `changes`
    link, a `history` that omits a chain turn;
  - `plans_from` naming a missing, unapproved, unclean or non-plan receipt, or a path or
    blob its `plan_blobs` lacks;
  - flipping `packets.conf` changes no decision on record.
- **`tests/xreview-skill.test.sh`**: the cap text is gone, and the new rules are pinned.
- **The replay harness** gets a dry-run mode, tested on one fixture case. It builds every
  arm's packet and the judge inputs without starting turns.

## 7. Rollout

1. The plan's first task checks the protocol facts the design assumes, against the live
   daemon:
   - whether `thread/fork` exists and what it copies, whether an archived historical thread
     can be forked, and how a fork is rewound to before a given turn (`thread/revert` or a
     fork point);
   - whether `turn/start` takes a per-turn working directory;
   - whether a `contextCompaction` item appears in the turn listing that xreview-rpc reads
     (`itemsView: "summary"`);
   - how a TUI `/compact` and a TUI rewind show up in that listing;
   - which rollout record carries the context size.

   A fact that does not hold changes this spec before any other task starts.

   **Verified 2026-10-25** (Codex 0.164.0; protocol schema from
   `codex app-server generate-json-schema`, then two spikes on scratch threads):
   - **Compaction.** A compaction is a `contextCompaction` item. It is listed only with
     `itemsView: "full"`; `"summary"` omits it, so every check here lists `full`. A mid-turn
     compaction is an item inside that review turn. Confirmed on a past review turn whose
     rollout holds a `compacted` record. A thread-level `/compact` (`thread/compact/start`)
     is a turn of its own, holding only that item. It also ends a turn still running, as
     `interrupted`.
   - **Rewind.** A TUI rewind is `thread/revert` with `beforeTurnId`. It removes that turn and
     every later one from `thread/turns/list`, so a missing chain turn shows.
   - **Fork.** `thread/fork` takes `lastTurnId` (fork through that turn, inclusive), `cwd` and
     `excludeTurns`. Rewinding a fork is forking through the turn before round k; no
     separate revert is needed. An archived thread is refused ("is archived … unarchive it
     first"). The replay runs `thread/unarchive`, forks, then archives the thread again.
   - **Per-turn working directory.** `turn/start` takes `cwd`, applied to this turn and later
     ones. Confirmed: the turn's `turn_context` and its shell ran in the given directory.
   - **Context size.** The rollout's latest `event_msg` `token_count` record:
     `info.last_token_usage.total_tokens` is the context now (after a compaction it already
     reflects the compacted size, input 0), and `info.model_context_window` is the window.
     `task_started` carries `model_context_window` too.
2. Implement everything on the branch with all switches off. With every switch off,
   behaviour is unchanged: receipts gain the new fields, and the gate reads none of them.
3. Run the replay from the branch checkout. It imports the working tree's packet builder and
   runs the working tree's `xreview-rpc`, so nothing needs deploying first. Record the results
   in §9. Turn on each switch that passed, one commit per switch, citing its result.
4. A switch that fails stays off. Its follow-up is a change to this spec, not a silent retry.
5. Pre-merge review, then push the branch. Michael merges and runs `chezmoi apply`, which
   deploys the code and the switch states together.

## 8. Risks and limits

- **Ten cases detect a real quality drop, not a small one.** Differences smaller than the
  noise between two identical runs cannot be told apart, at any sample size this budget allows.
- **Replay is not production.** It differs in three ways, each affecting every arm alike:
  - Scratch clones lack untracked files and trusted `mise` configuration, so a reviewer that
    runs code may see different results there.
  - The historical review bodies were temporary files and are gone, so every arm gets the
    same generic body. Settled points and constraints that the original rounds carried are
    missing.
  - A fork that fails makes its arm an error run, and that switch stays incomplete. There
    is no fallback replay of the earlier rounds (ruling during execution; forking was
    verified live).
  - A scratch clone holds only the branch at the round's tip and its destination at the
    base. It shares the source's object store, though, so a reviewer that deliberately
    enumerates objects (`git cat-file --batch-all-objects`) could still find later commits.
    No ref leads to them.
- **Coverage is self-reported.** `reviewed_files` catches a reviewer that admits skipping a
  file, not one that lists a file it skimmed. Attention cannot be measured from outside.
- **Constants are measured today.** 3.5 bytes per token, the 30k fresh-thread start, the
  60k reserve and 0.9 of the window come from current models. The fit check reads the window
  from the thread itself, but the others are fixed. A turn that compacts anyway is caught by
  the clean check and costs a round, never a wrong approval.
- **A fresh thread forgets earlier rounds.** After a move (§3.2 step 3), only the body's
  settled list stops the reviewer re-raising a point already ruled on. A re-raise still
  escalates under the skill.
- **Sliced reviews repeat every round.** 15 of 556 turns today (2.7%) would be sliced. Each
  of their rounds re-reviews every slice.
- **A file split into parts is never seen whole in one turn.** Each part's reviewer can open
  the rest of the file, but nothing makes it.
- **The history check is only as good as the turn listing.** If a rewind or compaction does
  not show up there, a delta could follow a thread that lost content. The plan's first task
  checks this (§7), and a gap falls back to full packets.

## 9. Replay results

Run 2026-10-25 from this branch: 27 cases, 88 arm turns (all completed, none errored or
interrupted), 38.1M Codex tokens, no stop (`stopped_at` none), at gpt-6-astra, effort
medium. 36 historical rounds were judged for known-real findings; 44 of their 47 P0–P2
findings were judged known-real.

| Switch | Cases | Known-real | Recall A / A′ / F / B | P0/P1 missed | Coverage failures | Tokens A / A′ / F / B | Compactions A / A′ / F / B |
|---|---|---|---|---|---|---|---|
| `framing` | 10 | 12 | 0.25 / 0.17 / 0.42 / 0.33 | 0 | 0% | 3.29M / 3.51M / 3.38M / 2.65M | 0 / 0 / 0 / 0 |
| `omit_plans` | 10 | 12 | 0.25 / 0.17 / – / 0.33 | 0 | 0% | 3.29M / 3.51M / – / 2.65M | 0 / 0 / – / 0 |
| `delta` | 10 | 13 | 0.62 / 0.62 / – / 0.54 | 1 | 0% | 3.47M / 3.85M / – / 3.03M | 0 / 0 / – / 0 |
| `fit` | 6 | 6 | 0.83 / 0.67 / – / 0.33 | 1 | 0% | 4.74M / 4.59M / – / 5.64M | 2 / 2 / – / 0 |

- The `framing` cases are the `omit_plans` cases (§5.1), so the two rows share A, A′ and B.
- `fit` ran on the 6 cases that had local commits and a known-real finding: 2 slicing and
  4 fresh-thread cases, fewer than §5.1's 7 + 5.
- Samples are small: one finding moves a recall by 0.08 (framing), 0.08 (delta) or 0.17
  (fit).

Switch states that follow (§5.5):

- **`framing`: on.** F and B recall at least the lower of A and A′, miss no P0/P1 both found,
  and no framed run failed coverage. F (framing alone) used about 3% more tokens than A; B
  (framing with `omit_plans`) about 19% fewer.
- **`omit_plans`: on.** B meets the bar on the same cases.
- **`delta`: off.** B recalled less than both A and A′ and missed a P0/P1 that both found.
- **`fit`: off.** B recalled less than both A and A′ and missed a P0/P1 that both found, though
  it avoided the compactions A and A′ hit. With `fit` off, the size cap stays in force
  (§3.8), so dispatch still refuses a packet over `XREVIEW_MAX_DIFF_BYTES`.
