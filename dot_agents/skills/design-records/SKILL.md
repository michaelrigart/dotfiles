---
name: design-records
description: Use when creating, updating, reviewing, completing, abandoning or deleting a spec or plan under `docs/superpowers/`, setting its Status, or working across repositories.
---

# Design records

## Records

Every change except a small one (see Sizing) has a spec and a plan, versioned with the code.

## Size and increments

Every spec has a `**Size:**` line: the estimated lines of non-test code (added plus deleted; design records and other docs not counted) and what the estimate rests on, such as the files it expects to touch or a comparable earlier change. Michael never has to produce or check this number; it is there so the split happens before the code exists.

A spec whose estimate is over about 500 lines has an `## Increments` section. Each increment has a name, what it delivers, its own estimate, and one sentence on why the default branch works once it is merged alone. Aim for a few hundred lines per increment. About 2,000 is the ceiling: an increment estimated over it is split again. If one truly cannot be split (a generated file, a mechanical rename), the spec says why, and that exception is part of what Michael signs.

Work that needs several pieces before anything works is still split: the early increments merge behind a flag, or unreferenced. The spec says which, and names the increment that turns it on.

The spec covers the whole change; a plan covers one increment and lists its tasks. Later increments may be planned after earlier ones have merged, because the earlier ones show the real shape. A plan is still committed before its execution starts, and Codex still reviews every plan.

If an increment's real size passes its estimate by half, or passes the ceiling, the line stops and reports it with a proposed split. That is a spec change, so it goes to Michael. Where the signed spec records that the increment cannot be split, passing the ceiling does not stop the line; passing its estimate by half still does.

The spec, and the first increment's plan, merge with the first increment. The spec's status stays `In progress` until the last increment's final commit sets `Implemented`. An increment that is dropped is recorded in the spec as dropped, with the reason, by the increment that turns out to be the last.

A spec with no `**Size:**` line predates v2 and finishes without increments.

## Status

Use exactly: `Approved`, `In progress`, `Implemented`, `Superseded — see <link>`, `Abandoned — <reason>`.

## Permanence

A spec is permanent from sign-off. Specs and plans are never deleted, pruned or gitignored, except material that must go on security or legal grounds (secrets, PII, customer data; rotate anything exposed).

## Abandoning and legacy records

An abandoned spec is marked `Abandoned` and merged on its own. Legacy records keep their status until verified against history.

## Completed documents

Mark a completed plan so it is not run again; its execution banners bind that run only, never repository policy. Durable lessons go in the spec, plan, ADR or MR description, never in raw run files.

Don't rewrite point-in-time facts.

## Cross-repo work

Keep one canonical spec, referenced by repository and path, preferably as a forge link and never as a bare path.

Open both MRs before merging either; merge the canonical spec's MR first.
