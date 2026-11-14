#!/usr/bin/env bash
# SubagentStart hook: adds one line of context in front of every subagent's first prompt, saying
# that a `cd` never carries over between its Bash calls and that the path-resolution guard denies
# a command that starts with one.
#
# The sp-* bodies state the same rule, but a body is the subagent's system prompt, and Sonnet 5.5
# does not act on it there: with the rule in its body, 4.0% of an sp-standard's Bash calls were
# still denied, against 3.5% without it. The same line in the first user turn stops it (measured
# 2026-11-14: 8 of 8 dispatches denied on their first call without it, 0 of 6 with it in the
# brief, and 0 of 3 first calls with it from this hook). The text is that measured line.
#
# It never decides: it prints context only, and SubagentStart cannot block a dispatch anyway. It
# never reads the payload. It fails open and silent: any error leaves stdout and stderr empty and
# exits 0, so a broken hook costs the line, never the dispatch.
# Runs outside the sandbox, so it resolves nothing a sandboxed command can write (spec
# 2026-10-16, sandbox write boundary). PINNED_PATH is for the suites only.
PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH
set -uo pipefail

# Drain stdin: leaving the payload unread hands the writer an EPIPE.
cat >/dev/null 2>&1 || exit 0

line="Shell: every Bash call starts fresh in the session's directory and a \`cd\` never carries over, so never begin a command with \`cd\` (the path guard denies it). Name every file by its absolute path."
jq -cn --arg c "$line" '{hookSpecificOutput:{hookEventName:"SubagentStart",additionalContext:$c}}' 2>/dev/null
exit 0
