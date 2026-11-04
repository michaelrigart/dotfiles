#!/usr/bin/python3
"""process-replay - measure, from October's recorded reviews, whether parts of the review process can go.

Design: docs/superpowers/specs/2026-11-02-replay-set-design.md. It imports xreview-replay.py for its
turn runner, rollout reading and judge-file conventions, never copies them, and never writes into an
original repository, ~/.claude/projects or ~/.codex.

  snapshot       copy the task-review transcripts, and read commits from the object snapshot
  cases          pick the branches and the defects of both classes
  inject         build each injected tree, validate its defects, qualify the branches
  run            the gates that stay, on a fresh Codex thread per run
  match          apply the answers that came in (final reviews, matches, rulings) to the runs; starts no round, makes no run
  report         the pass bar and the costs
  cleanup        archive the runs' threads, stop the replay home's daemon, remove the scratch trees, work and view repositories and staged items
  pending        list what waits for an agent: judge inputs, final reviews, recreations
  home           the replay Codex homes and their daemon
  memories-watch watch the Codex memories directory and snapshot it on change
  relocate-snapshot  move the snapshot and rewrite the state's references to it

Usage: process-replay.py <command> [--state DIR] [--dry-run] [--snapshot-root DIR] [--projects-dir DIR]
                         [--max-tokens N] [--budget SECS] [command flags]

Each command's module is imported only when it runs. Its flags come from its module's
add_args_<command>(parser) (dashes as underscores), else add_args(parser), when it has one.
--dry-run starts no daemon and no turn, and writes nothing but judge inputs and briefs.
The default state directory is $XDG_STATE_HOME/process-replay/<date>, and the default --snapshot-root
$XDG_STATE_HOME/process-replay/snapshot/2026-11-02.

Locks (process_replay.common.command_locks), each held from the command's entry to its exit: `run` shares <state>/run.lock
with `match`, `pending`, `report`, `home` (but --login-cmd) and `cases --plans`, and holds <state>/runner.lock alone;
`snapshot`, `cases`, `inject`, `cleanup` and `relocate-snapshot` hold run.lock alone. `run`, `cleanup` and `home` also hold the replay daemons'
lock; memories-watch holds none. A dry run that writes nothing takes no lock. A command that finds a lock held in a mode that conflicts
with its own exits 1, naming it, before it has changed anything.

Written for /usr/bin/python3 (3.9).
"""
import argparse
import importlib
import os
import signal
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

COMMANDS = {
    "snapshot": ("transcripts", "cmd_snapshot"),
    "cases": ("inventory", "cmd_cases"),
    "inject": ("inject", "cmd_inject"),
    "run": ("loop", "cmd_run"),
    "match": ("loop", "cmd_match"),
    "report": ("bar", "cmd_report"),
    "cleanup": ("loop", "cmd_cleanup"),
    "pending": ("common", "cmd_pending"),
    "home": ("codexhome", "cmd_home"),
    "memories-watch": ("memwatch", "cmd_memories_watch"),
    "relocate-snapshot": ("relocate", "cmd_relocate_snapshot"),
}
SNAPSHOT_DAY = "2026-11-02"


def snapshot_root_default():
    """The snapshot of October's objects: <snapshot home>/2026-11-02 (common.snapshot_home)."""
    from process_replay import common
    return os.path.join(common.snapshot_home(), SNAPSHOT_DAY)


def usage():
    return "usage: process-replay.py <command> [flags]\ncommands: " + ", ".join(COMMANDS) + "\n"


def main(argv):
    if not argv:
        sys.stderr.write(usage())
        return 2
    if argv[0] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0
    command = argv[0]
    if command not in COMMANDS:
        sys.stderr.write("process-replay: unknown command {!r}\n{}".format(command, usage()))
        return 2
    from process_replay import common
    module_name, func_name = COMMANDS[command]
    ap = argparse.ArgumentParser(prog="process-replay " + command)
    ap.add_argument("--state", default=common.state_default())
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--snapshot-root", default=snapshot_root_default())
    ap.add_argument("--projects-dir", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--max-tokens", type=int, default=100000000)
    ap.add_argument("--budget", type=float, default=3600)
    module = importlib.import_module("process_replay." + module_name)
    add = getattr(module, "add_args_" + command.replace("-", "_"), None) or getattr(module, "add_args", None)
    if add:
        add(ap)
    a = ap.parse_args(argv[1:])
    a.command = command
    a.state = os.path.abspath(a.state)
    os.makedirs(a.state, exist_ok=True)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, common.XR.on_signal)
    try:
        return getattr(module, func_name)(a) or 0
    except common.Failed as e:
        sys.stderr.write("process-replay: {}\n".format(e))
        return 1
    except KeyboardInterrupt:
        sys.stderr.write("process-replay: interrupted\n")
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
