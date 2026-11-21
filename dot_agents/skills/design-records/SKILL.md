---
name: design-records
description: Use when creating, updating, reviewing, completing, abandoning or deleting a spec or plan under `docs/superpowers/`, or setting its Status.
---

# Design records

## Records

Every change except a small one (see Sizing) has a spec and a plan, versioned with the code.

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
