#!/usr/bin/env python3
"""Mutation-audit harness for the dotfiles test suites.

Runs suites in a private copy of the repository under the run.sh machine lock, reads
their assertions the way tests/run.sh counts them, and attributes kills. Stdlib only.
"""
import argparse
import dataclasses
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DEFAULT_SEED = 20261111
BASELINE_TIMEOUT = 1800
LANGS = {"bash", "zsh", "sh", "py", "prose", "data", "deployed"}
GIT_IDENT = ["-c", "user.name=test-audit", "-c", "user.email=test-audit@localhost",
             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]

PASS_RE = re.compile(r"^\s*(ok|PASS)(\s|:)")
FAIL_RE = re.compile(r"^\s*(FAIL|not ok)(\s|:)")
LABEL_RE = re.compile(r"^\s*(?:ok|PASS|FAIL|not ok)(?:\s|:)\s*:?\s*(.*)$")
KV_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*=[A-Za-z_]+$")
TMP_RE = re.compile(r"(?<![\w.~-])(?:/private)?/(?:tmp|var/folders)(?:/[^\s'\"]*)?")


def die(message):
    print(message, file=sys.stderr)
    sys.exit(2)


def kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        pass
    proc.wait()


class Lock:
    """The run.sh lock: lockf -k is an flock on this file, so flock interoperates."""

    def __init__(self, path):
        self.path = str(path)
        self.fd = None

    def acquire(self):
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        self.fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"waiting for the test-run lock {self.path}", file=sys.stderr, flush=True)
            fcntl.flock(self.fd, fcntl.LOCK_EX)

    def release(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


class Session:
    """Everything a process must undo on any exit, in the order the plan fixes."""

    def __init__(self):
        self.proc = None
        self.restores = []
        self.copies = []
        self.locks = []

    def apply_text(self, path, text):
        self.restores.append((path, path.read_bytes()))
        path.write_text(text)

    def cleanup(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, signal.SIG_IGN)
        if self.proc is not None:
            kill_group(self.proc)
            self.proc = None
        for path, data in reversed(self.restores):
            try:
                path.write_bytes(data)
            except OSError:
                pass
        self.restores.clear()
        for copy in self.copies:
            shutil.rmtree(copy, ignore_errors=True)
        self.copies.clear()
        for lock in self.locks:
            lock.release()
        self.locks.clear()


SESSION = Session()


@dataclasses.dataclass
class Run:
    rc: int | None
    seconds: float
    timed_out: bool
    passed: list
    failed: list
    output: str


class Store:
    def __init__(self, state):
        self.state = Path(state)

    def _path(self, kind):
        return self.state / f"runs-{kind}.jsonl"

    def append(self, kind, record):
        self.state.mkdir(parents=True, exist_ok=True)
        with open(self._path(kind), "a") as f:
            f.write(json.dumps(record) + "\n")

    def records(self, kind):
        path = self._path(kind)
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def meta(self):
        path = self.state / "meta.json"
        return json.loads(path.read_text()) if path.exists() else {}

    def bind(self, sha):
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / "meta.json").write_text(json.dumps({"sha": sha}) + "\n")


def build_copy(repo, sha, root, command):
    root = Path(root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    copy = root / f"{sha[:12]}-{command}-{os.getpid()}"
    shutil.rmtree(copy, ignore_errors=True)
    copy.mkdir()
    SESSION.copies.append(copy)
    archive = subprocess.Popen(["git", "-C", str(repo), "archive", sha], stdout=subprocess.PIPE)
    untar = subprocess.run(["tar", "-x", "-C", str(copy)], stdin=archive.stdout)
    archive.stdout.close()
    if archive.wait() != 0 or untar.returncode != 0:
        die(f"cannot archive {sha} from {repo}")
    for args in (["init", "-q"], ["add", "-A"], [*GIT_IDENT, "commit", "-q", "-m", "audit copy"]):
        subprocess.run(["git", "-C", str(copy), *args], check=True, stdout=subprocess.DEVNULL)
    return copy


def header(script, key):
    """The first `# <key>: value` line, as run.sh's sed reads it."""
    prefix = f"# {key}:"
    for line in script.read_text(errors="replace").split("\n"):
        if line.startswith(prefix):
            return line[len(prefix):].lstrip(" ").split("  #")[0]
    return ""


def has_serial_tag(script):
    return any(re.match(r"^# test-serial(\s|$)", line)
               for line in script.read_text(errors="replace").split("\n"))


def normalize(label, copy):
    for path in sorted({str(copy), os.path.realpath(copy)}, key=len, reverse=True):
        label = label.replace(path, "<copy>")
    return " ".join(TMP_RE.sub("<tmp>", label).split())


def parse_output(text, copy):
    """Passed and failed labels. A repeat of a label gets ` #n`, counted across both kinds."""
    passed, failed, seen = [], [], {}
    lines = text.split("\n")
    for line in lines:
        is_pass, is_fail = PASS_RE.match(line), FAIL_RE.match(line)
        if not (is_pass or is_fail):
            continue
        label = normalize(LABEL_RE.match(line).group(1), copy)
        seen[label] = seen.get(label, 0) + 1
        if seen[label] > 1:
            label = f"{label} #{seen[label]}"
        (passed if is_pass else failed).append(label)
    if not passed and not failed:
        # run.sh falls back to the KEY=VALUE idiom of the live-* suites.
        passed = [line for line in lines
                  if KV_RE.match(line) and not line.endswith("=SKIPPED")
                  and not line.startswith("failed_keys=")]
    return passed, failed


def run_suite(copy, suite, timeout, lock):
    copy = Path(copy)
    script = copy / "tests" / f"{suite}.test.sh"
    args = header(script, "test-args").replace("{repo}", str(copy)).split()
    env = {**os.environ, "RUN_SH_LOCKED": "1", "RUN_SH_START_DIR": str(copy),
           "RUN_SH_LOCK": str(lock)}
    guard = Lock(lock)
    SESSION.locks.append(guard)
    guard.acquire()
    timed_out = False
    with tempfile.TemporaryFile() as out:
        start = time.monotonic()
        proc = subprocess.Popen([f"./{suite}.test.sh", *args], cwd=copy / "tests",
                                stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                env=env, start_new_session=True)
        SESSION.proc = proc
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out, rc = True, None
        kill_group(proc)
        seconds = time.monotonic() - start
        SESSION.proc = None
        out.seek(0)
        text = out.read().decode(errors="replace")
    SESSION.locks.remove(guard)
    guard.release()
    passed, failed = parse_output(text, copy)
    return Run(rc, seconds, timed_out, passed, failed, text)


def baseline_ok(run):
    return run.rc == 0 and not run.timed_out and bool(run.passed) and not run.failed


def attribute(baseline, run):
    """(verdict, killers, unmatched) of a mutant run against a green baseline."""
    wanted = len(baseline.passed) + len(baseline.failed)
    if (run.timed_out or run.rc is None or len(run.passed) + len(run.failed) < wanted
            or (run.rc != 0 and not run.failed)):
        return "inconclusive", [], []
    if run.failed:
        known = set(baseline.passed)
        return ("killed", [x for x in run.failed if x in known],
                [x for x in run.failed if x not in known])
    return "survived", [], []


def suite_row(copy, suite):
    script = Path(copy) / "tests" / f"{suite}.test.sh"
    requires = header(script, "test-requires")
    return {
        "suite": suite,
        "lines": script.read_bytes().count(b"\n"),
        "requires": requires,
        "serial": has_serial_tag(script) or (requires not in ("", "heavy")),
    }


def load_subjects(path, explicit):
    path = Path(path)
    if not path.exists():
        if explicit:
            die(f"missing subjects file: {path}")
        return []
    rows = []
    for n, line in enumerate(path.read_text().split("\n"), 1):
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) != 4 or cols[1] not in LANGS:
            die(f"{path}:{n}: want file, lang, own_suite, loaded_by")
        rows.append({"file": cols[0], "lang": cols[1], "own_suite": cols[2],
                     "loaded_by": [s for s in cols[3].split(",") if s and s != "-"]})
    return rows


def refuse_if_writable(probe_dir):
    probe = os.path.join(probe_dir, f".test-audit-probe-{os.getpid()}")
    try:
        fd = os.open(probe, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except OSError:
        return
    os.close(fd)
    os.unlink(probe)
    die(f"refusing: {probe_dir} is writable, so this shell is not sandboxed")


def refuse_inside_repo(copy_root, repo):
    root, top = Path(copy_root).resolve(), Path(repo).resolve()
    if root == top or top in root.parents:
        die(f"refusing: copy root {copy_root} is inside the repository")


def resolve_sha(repo, ref):
    out = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "-q", f"{ref}^{{commit}}"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        die(f"cannot resolve {ref} in {repo}")
    return out.stdout.strip()


def prepare(args, command, bind):
    """Checks shared by every command that runs suites; returns the copy."""
    refuse_if_writable(args.probe_dir)
    refuse_inside_repo(args.copy_root, args.repo)
    store = Store(args.state)
    bound = store.meta().get("sha")
    sha = resolve_sha(args.repo, args.ref or bound or "main")
    if bind:
        if bound and sha != bound:
            die(f"state is bound to {bound}; use another --state")
        if not bound:
            store.bind(sha)
    return build_copy(args.repo, sha, args.copy_root, command)


def cmd_inventory(args):
    copy = prepare(args, "inventory", bind=True)
    store_path = Path(args.state) / "inventory.jsonl"
    rows = {}
    if store_path.exists():
        for line in store_path.read_text().splitlines():
            row = json.loads(line)
            rows[row["suite"]] = row
    available = sorted(p.name[:-len(".test.sh")] for p in (copy / "tests").glob("*.test.sh"))
    chosen = args.suites or available
    for suite in chosen:
        if suite not in available:
            die(f"no such suite: {suite}")
    for suite in chosen:
        row = suite_row(copy, suite)
        row.update(assertions=None, passed=None, failed=None, labels=[], rc=None, seconds=None)
        if row["requires"] in ("", "heavy"):
            run = run_suite(copy, suite, BASELINE_TIMEOUT, args.lock)
            row.update(assertions=len(run.passed) + len(run.failed), passed=len(run.passed),
                       failed=len(run.failed), labels=run.passed, rc=run.rc,
                       seconds=round(run.seconds, 3))
        rows[suite] = row
        tmp = store_path.with_suffix(".tmp")
        tmp.write_text("".join(json.dumps(r) + "\n" for r in rows.values()))
        os.replace(tmp, store_path)


def cmd_try(args):
    copy = prepare(args, "try", bind=False)
    target = copy / args.file
    script = copy / "tests" / f"{args.suite}.test.sh"
    if not script.exists():
        die(f"no such suite: {args.suite}")
    if header(script, "test-requires") not in ("", "heavy"):
        die(f"refusing: {args.suite} needs {header(script, 'test-requires')}, so it is never mutated")
    if not target.is_file():
        die(f"no such file: {args.file}")
    text = target.read_text()
    found = text.count(args.find)
    if found != 1:
        die(f"{args.find!r} occurs {found} times in {args.file}, want exactly 1")
    baseline = run_suite(copy, args.suite, BASELINE_TIMEOUT, args.lock)
    if not baseline_ok(baseline):
        result = {"verdict": "baseline-red", "killers": [], "unmatched": [], "rc": baseline.rc,
                  "seconds": round(baseline.seconds, 3), "timed_out": baseline.timed_out}
    else:
        SESSION.apply_text(target, text.replace(args.find, args.replace))
        timeout = max(args.timeout_floor, 3 * baseline.seconds)
        run = run_suite(copy, args.suite, timeout, args.lock)
        verdict, killers, unmatched = attribute(baseline, run)
        result = {"verdict": verdict, "killers": killers, "unmatched": unmatched, "rc": run.rc,
                  "seconds": round(run.seconds, 3), "timed_out": run.timed_out}
    print(json.dumps(result))


def cmd_report(args):
    path = Path(args.state) / "inventory.jsonl"
    rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    subjects = load_subjects(args.subjects, args.subjects_explicit)
    print("| suite | lines | assertions | seconds | requires | files loaded |")
    print("|---|---|---|---|---|---|")
    for row in sorted(rows, key=lambda r: r["suite"]):
        loaded = ", ".join(s["file"] for s in subjects if row["suite"] in s["loaded_by"])
        seconds = "-" if row["seconds"] is None else f"{row['seconds']:.1f}"
        assertions = "-" if row["assertions"] is None else row["assertions"]
        print(f"| {row['suite']} | {row['lines']} | {assertions} | {seconds} | "
              f"{row['requires'] or '-'} | {loaded or '-'} |")


def parser():
    here = Path(__file__).resolve().parent
    uid = os.getuid()
    p = argparse.ArgumentParser(prog="audit.py")
    p.add_argument("--repo")
    p.add_argument("--ref")
    p.add_argument("--state")
    p.add_argument("--subjects")
    p.add_argument("--copy-root", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "test-audit"))
    p.add_argument("--lock", default=os.environ.get("RUN_SH_LOCK") or f"/tmp/claude-{uid}/tests-run.lock")
    p.add_argument("--timeout-floor", type=float, default=60)
    p.add_argument("--probe-dir", default=os.environ.get("HOME", "/"))
    p.add_argument("--seed", type=int, default=DEFAULT_SEED)
    sub = p.add_subparsers(dest="command", required=True)
    inv = sub.add_parser("inventory")
    inv.add_argument("suites", nargs="*")
    inv.set_defaults(func=cmd_inventory)
    tr = sub.add_parser("try")
    for name in ("file", "find", "replace", "suite"):
        tr.add_argument(name)
    tr.set_defaults(func=cmd_try)
    rep = sub.add_parser("report")
    rep.add_argument("--section", required=True, choices=["inventory"])
    rep.set_defaults(func=cmd_report)
    p.set_defaults(harness_dir=here)
    return p


def on_signal(signum, _frame):
    sys.exit(128 + signum)


def main(argv=None):
    args = parser().parse_args(argv)
    if args.repo is None:
        top = subprocess.run(["git", "-C", str(args.harness_dir), "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True)
        if top.returncode != 0:
            die("cannot find the repository; pass --repo")
        args.repo = top.stdout.strip()
    args.state = args.state or os.path.join(args.repo, ".superpowers", "test-audit")
    args.subjects_explicit = args.subjects is not None
    args.subjects = args.subjects or str(args.harness_dir / "subjects.tsv")
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    try:
        args.func(args)
    finally:
        SESSION.cleanup()
    return 0


if __name__ == "__main__":
    sys.exit(main())
