#!/usr/bin/env python3
"""Mutation-audit harness for the dotfiles test suites.

Runs suites in a private copy of the repository under the run.sh machine lock, reads
their assertions the way tests/run.sh counts them, and attributes kills. Stdlib only.
"""
import argparse
import dataclasses
import errno
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
import random
import hashlib
import shlex
import zlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mutators  # noqa: E402
import rules  # noqa: E402

DEFAULT_SEED = 20261111
BASELINE_TIMEOUT = 1800
LANGS = {"bash", "zsh", "sh", "py", "prose", "data", "deployed"}
HEAVY_SAMPLE = {"xreview": 3, "git-forge-guard": 6, "wt-functions": 8, "process-replay": 2}
KINDS = {"code": "sample", "targeted": "targeted", "rule": "rules"}
CHECK_SUITE = "check"
SAFETY_SUITES = {
    "chezmoi-wrapper", "claude-settings", "codex-config", "deny-modes-probe", "git-forge-guard",
    "git-signing-config", "ha-mcp", "hook-path", "install-claude-managed-settings",
    "path-resolution-guard", "sdd-clean", "ssh-sandbox-proxy", "unifi-network-mcp",
    "worktree-guard", "write-boundary-probe", "wt-functions", "wt-teardown", "xreview",
    "xreview-apply-guard", "xreview-guard", "xreview-ledger", "xreview-skill",
}
GIT_IDENT = ["-c", "user.name=test-audit", "-c", "user.email=test-audit@localhost",
             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]

PASS_RE = re.compile(r"^\s*(ok|PASS)(\s|:)")
FAIL_RE = re.compile(r"^\s*(FAIL|not ok)(\s|:)")
LABEL_RE = re.compile(r"^\s*(?:ok|PASS|FAIL|not ok)(?:\s|:)\s*:?\s*(.*)$")
KV_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*=[A-Za-z_]+$")
TMP_RE = re.compile(r"(?<![\w.~-])(?:/private)?/(?:tmp|var/folders)(?:/[^\s'\"]*)?")


STOP_SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)


def die(message):
    print(message, file=sys.stderr)
    sys.exit(2)


def make_writable(path):
    if os.path.islink(path) or not os.path.isdir(path):
        return
    try:
        os.chmod(path, 0o700)
        for name in os.listdir(path):
            make_writable(os.path.join(path, name))
    except OSError:
        pass


def remove_tree(path):
    shutil.rmtree(path, ignore_errors=True)
    if not os.path.lexists(path):
        return
    make_writable(path)
    shutil.rmtree(path, ignore_errors=True)
    if os.path.lexists(path):
        print(f"copy left behind: {path}", file=sys.stderr)


def inside_copy(copy, relative):
    """The caller-supplied path joined onto the copy, which must resolve inside it."""
    copy = Path(copy).resolve()
    target = (copy / relative).resolve()
    if copy not in target.parents:
        die(f"refusing: {relative} resolves to {target}, outside the copy {copy}")
    return target


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

    def try_acquire(self):
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        self.fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.fd)
            self.fd = None
            return False
        return True

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

    def restore_files(self):
        for path, data in reversed(self.restores):
            try:
                path.write_bytes(data)
            except OSError:
                pass
        self.restores.clear()

    def cleanup(self):
        for sig in STOP_SIGNALS:
            signal.signal(sig, signal.SIG_IGN)
        if self.proc is not None:
            kill_group(self.proc)
            self.proc = None
        self.restore_files()
        for copy in self.copies:
            remove_tree(copy)
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
        """Append one record. A last line a crash left without its newline is completed when it
        parses and dropped when it does not, so the new record never fuses with it."""
        self.state.mkdir(parents=True, exist_ok=True)
        path = self._path(kind)
        with open(path, "ab+") as f:
            f.seek(0)
            data = f.read()
            if data and not data.endswith(b"\n"):
                cut = data.rfind(b"\n") + 1
                try:
                    json.loads(data[cut:])
                    f.write(b"\n")
                except ValueError:
                    f.truncate(cut)
            f.write((json.dumps(record) + "\n").encode())

    def records(self, kind):
        path = self._path(kind)
        if not path.exists():
            return []
        lines = [line for line in path.read_text().splitlines() if line.strip()]
        records = []
        for n, line in enumerate(lines):
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                if n < len(lines) - 1:
                    raise
        return records

    def meta(self):
        path = self.state / "meta.json"
        return json.loads(path.read_text()) if path.exists() else {}

    def bind(self, sha, **extra):
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / "meta.json").write_text(json.dumps({**self.meta(), "sha": sha, **extra}) + "\n")


def build_copy(repo, sha, root, command):
    root = Path(root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    copy = root / f"{sha[:12]}-{command}-{os.getpid()}"
    remove_tree(copy)
    copy.mkdir()
    SESSION.copies.append(copy)
    archive = subprocess.Popen(["git", "-C", str(repo), "archive", sha], stdout=subprocess.PIPE)
    untar = subprocess.run(["tar", "-x", "-C", str(copy)], stdin=archive.stdout)
    archive.stdout.close()
    if archive.wait() != 0 or untar.returncode != 0:
        die(f"cannot archive {sha} from {repo}")
    for args in (["-c", "init.templateDir=", "init", "-q", "-b", "main"], ["add", "-A"],
                 [*GIT_IDENT, "commit", "-q", "-m", "audit copy"]):
        subprocess.run(["git", "-C", str(copy), *args], check=True, stdout=subprocess.DEVNULL)
    return copy


def header_of(text, key):
    """The first `# <key>: value` line of a script's text, as run.sh's sed reads it."""
    prefix = f"# {key}:"
    for line in text.split("\n"):
        if line.startswith(prefix):
            return line[len(prefix):].lstrip(" ").split("  #")[0]
    return ""


def header(script, key):
    return header_of(script.read_text(errors="replace"), key)


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
    return run_process(copy, [f"./{suite}.test.sh", *args], copy / "tests", timeout, lock)


def run_check(copy, argv, timeout, lock):
    """One run of a rule checker as a pseudo-suite, its output read like a suite's."""
    return run_process(Path(copy), argv, Path(copy), timeout, lock)


def synthesize_check(run):
    """A checker that prints no assertion lines is one assertion, `check`: passed on exit 0, failed
    on any other exit."""
    if not run.passed and not run.failed and not run.timed_out:
        if run.rc == 0:
            run.passed = [CHECK_SUITE]
        else:
            run.failed = [CHECK_SUITE]
    return run


def run_process(copy, argv, cwd, timeout, lock):
    env = {**os.environ, "RUN_SH_LOCKED": "1", "RUN_SH_START_DIR": str(copy),
           "RUN_SH_LOCK": str(lock)}
    guard = Lock(lock)
    SESSION.locks.append(guard)
    guard.acquire()
    timed_out = False
    with tempfile.TemporaryFile() as out:
        start = time.monotonic()
        # A stop signal between Popen and the assignment would leave the new-session suite
        # running, so it waits; the child gets an empty mask back before it execs.
        signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
        try:
            proc = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                    env=env, start_new_session=True,
                                    preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, ()))
            SESSION.proc = proc
        finally:
            signal.pthread_sigmask(signal.SIG_UNBLOCK, STOP_SIGNALS)
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
    """(verdict, killers, unmatched, ambiguous, via_detail) of a mutant run against a green baseline."""
    wanted = len(baseline.passed) + len(baseline.failed)
    if (run.timed_out or run.rc is None or len(run.passed) + len(run.failed) < wanted
            or (run.rc != 0 and not run.failed)):
        return "inconclusive", [], [], [], []
    if not run.failed:
        return "survived", [], [], [], []
    killers, unmatched, ambiguous, exact, detail = [], [], [], set(), set()
    for label in run.failed:
        how, killer = classify_failed(label, baseline.passed)
        if how == "unmatched":
            unmatched.append(label)
        elif how == "ambiguous":
            ambiguous.append(label)
        else:
            if killer not in killers:
                killers.append(killer)
            (exact if how == "exact" else detail).add(killer)
    if not killers and not unmatched:
        return "inconclusive", [], [], ambiguous, []
    return "killed", killers, unmatched, ambiguous, [k for k in killers if k in detail and k not in exact]


def classify_failed(failed, baseline_passed):
    """How a failed label maps to the baseline: ('exact'|'detail', killer label), ('ambiguous', None)
    when several baseline labels qualify as its prefix (R8), or ('unmatched', None). git-forge-guard
    prints `FAIL x (want a, got b)` for the baseline's `ok x`."""
    known = set(baseline_passed)
    if failed in known:
        return "exact", failed
    cands = [p for p in known if failed.startswith(p + " (")]
    if len(cands) == 1:
        return "detail", cands[0]
    return ("ambiguous", None) if cands else ("unmatched", None)


def run_result(baseline, run):
    verdict, killers, unmatched, ambiguous, via = attribute(baseline, run)
    return {"verdict": verdict, "killers": killers, "unmatched": unmatched, "ambiguous": ambiguous,
            "via_detail": via, "rc": run.rc, "seconds": round(run.seconds, 3),
            "timed_out": run.timed_out}


def red_result(baseline):
    return {"verdict": "baseline-red", "killers": [], "unmatched": [], "ambiguous": [],
            "via_detail": [], "rc": baseline.rc, "seconds": round(baseline.seconds, 3),
            "timed_out": baseline.timed_out}


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
    except OSError as err:
        if err.errno in (errno.EACCES, errno.EPERM, errno.EROFS):
            return
        die(f"refusing: cannot probe {probe_dir}: {err.strerror}")
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


def preflight(args, bind):
    """Checks shared by every command that runs suites; returns the commit to measure."""
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
    return sha


def prepare(args, command, bind):
    return build_copy(args.repo, preflight(args, bind), args.copy_root, command)


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
    target = inside_copy(copy, args.file)
    script = inside_copy(copy, Path("tests") / f"{args.suite}.test.sh")
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
        result = red_result(baseline)
    else:
        SESSION.apply_text(target, text.replace(args.find, args.replace))
        timeout = max(args.timeout_floor, 3 * baseline.seconds)
        result = run_result(baseline, run_suite(copy, args.suite, timeout, args.lock))
    print(json.dumps(result))


def report_inventory(args):
    rows = list(load_inventory(args.state).values())
    subjects = load_subjects(args.subjects, args.subjects_explicit)
    print("| suite | lines | assertions | seconds | requires | files loaded |")
    print("|---|---|---|---|---|---|")
    for row in sorted(rows, key=lambda r: r["suite"]):
        loaded = ", ".join(s["file"] for s in subjects if row["suite"] in s["loaded_by"])
        seconds = "-" if row["seconds"] is None else f"{row['seconds']:.1f}"
        assertions = "-" if row["assertions"] is None else row["assertions"]
        print(f"| {row['suite']} | {row['lines']} | {assertions} | {seconds} | "
              f"{row['requires'] or '-'} | {loaded or '-'} |")


def load_inventory(state):
    path = Path(state) / "inventory.jsonl"
    if not path.exists():
        return {}
    return {r["suite"]: r for r in (json.loads(line) for line in path.read_text().splitlines()
                                    if line.strip())}


def read_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def write_atomic(path, text):
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def git_show(repo, sha, file):
    out = subprocess.run(["git", "-C", str(repo), "show", f"{sha}:{file}"], capture_output=True)
    return out.stdout.decode(errors="replace") if out.returncode == 0 else None


def state_sha(args):
    return resolve_sha(args.repo, args.ref or Store(args.state).meta().get("sha") or "main")


def infer_lang(file, text):
    if file.endswith(".py"):
        return "py"
    first = text.split("\n", 1)[0]
    for lang in ("zsh", "bash", "sh"):
        if re.match(rf"#!.*\b{lang}\b", first):
            return lang
    return None


def cmd_mutants(args):
    sha = state_sha(args)
    text = git_show(args.repo, sha, args.file)
    if text is None:
        die(f"no such file at {sha[:12]}: {args.file}")
    row = next((r for r in load_subjects(args.subjects, args.subjects_explicit)
                if r["file"] == args.file), None)
    lang = row["lang"] if row else infer_lang(args.file, text)
    if lang not in (*mutators.SHELLS, "py"):
        die(f"no code mutants for {args.file} (lang {lang})")
    for mutant in mutators.code_mutants(args.file, text, lang):
        print(json.dumps(mutant))


def sample_size(suite, seconds, valid):
    n = HEAVY_SAMPLE.get(suite) or max(4, min(20, int(900 // max(seconds, 1e-6))))
    return min(n, valid)


def pick(file, mutants, n, seed):
    """Stratified: round-robin over the operators in order, random within an operator."""
    rng = random.Random(seed ^ zlib.crc32(file.encode()))
    pools = {op: [m for m in mutants if m["op"] == op] for op in mutators.OPS}
    for op in mutators.OPS:
        rng.shuffle(pools[op])
    chosen = []
    while len(chosen) < n and any(pools.values()):
        for op in mutators.OPS:
            if pools[op] and len(chosen) < n:
                chosen.append(pools[op].pop())
    return sorted(chosen, key=lambda m: (m["line"], m["col"], m["op"]))


def cmd_plan(args):
    inventory = load_inventory(args.state)
    sha = Store(args.state).meta().get("sha")
    if not inventory or not sha:
        die("run inventory first")
    state = Path(args.state)
    sample_path, files_path = state / "sample.jsonl", state / "sample-files.jsonl"
    if not sample_path.exists():
        files, rows = [], []
        subjects = [r for r in load_subjects(args.subjects, args.subjects_explicit)
                    if r["lang"] in (*mutators.SHELLS, "py")]
        for subject in subjects:
            if subject["own_suite"] not in ("", "-") and subject["own_suite"] not in inventory:
                die(f"inventory incomplete: {subject['own_suite']}")
        for subject in subjects:
            file, suite = subject["file"], subject["own_suite"]
            info = inventory.get(suite)
            if suite in ("", "-") or suite_status(info) == "gated":
                files.append({"file": file, "suite": suite, "valid": None, "sampled": 0, "seconds": None})
                continue
            if suite_status(info) == "red":
                files.append({"file": file, "suite": suite, "valid": None, "sampled": 0, "seconds": None,
                              "copy_red": True})
                continue
            text = git_show(args.repo, sha, file)
            if text is None:
                die(f"{file} is in the subject map but not in {sha[:12]}")
            valid = mutators.code_mutants(file, text, subject["lang"])
            chosen = pick(file, valid, sample_size(suite, info["seconds"], len(valid)), args.seed)
            files.append({"file": file, "suite": suite, "valid": len(valid), "sampled": len(chosen),
                          "seconds": info["seconds"]})
            rows += [{**m, "suite": suite, "valid": len(valid)} for m in chosen]
        write_atomic(files_path, "".join(json.dumps(f) + "\n" for f in files))
        write_atomic(sample_path, "".join(json.dumps(r) + "\n" for r in rows))
    files = read_jsonl(files_path) if files_path.exists() else []
    print("| file | own suite | valid | sampled | est. minutes |")
    print("|---|---|---|---|---|")
    total, seconds, baselines = 0, 0.0, {}
    for f in sorted(files, key=lambda f: f["file"]):
        est = f["sampled"] * (f["seconds"] or 0) * 1.2
        if f["sampled"]:
            baselines[f["suite"]] = f["seconds"]
        total, seconds = total + f["sampled"], seconds + est
        valid = "-" if f["valid"] is None else f["valid"]
        print(f"| {f['file']} | {f['suite']} | {valid} | {f['sampled']} | {est / 60:.1f} |")
    seconds += sum(baselines.values())
    red = [f["file"] for f in sorted(files, key=lambda f: f["file"]) if f.get("copy_red")]
    if red:
        print(f"copy-red: {', '.join(red)}")
    print(f"total: {total} mutants, ~{seconds / 3600:.1f} h")


def qualified(suite, labels):
    return [f"{suite}::{label}" for label in labels]


def combine(results):
    """One mutant's outcome from its per-suite results: killed beats inconclusive beats
    baseline-red beats survived. Labels are qualified as suite::label."""
    verdicts = [r["verdict"] for r in results.values()]
    verdict = next((v for v in ("killed", "inconclusive", "baseline-red") if v in verdicts), "survived")
    out = {"verdict": verdict, "killers": [], "unmatched": [], "ambiguous": [], "via_detail": [],
           "suites": {}, "flaky": False, "attempts": 1, "seconds": 0.0}
    for suite, r in results.items():
        for key in ("killers", "unmatched", "ambiguous", "via_detail"):
            out[key] += qualified(suite, r[key])
        out["suites"][suite] = r["verdict"]
        out["flaky"] = out["flaky"] or bool(r.get("flaky"))
        if r.get("rerun") == "skipped":
            out["rerun"] = "skipped"
        out["attempts"] = max(out["attempts"], r.get("attempts", 1))
        out["seconds"] += r["seconds"]
    out["seconds"] = round(out["seconds"], 3)
    return out


def stale_outcome():
    return {"verdict": "stale", "killers": [], "unmatched": [], "ambiguous": [], "via_detail": [],
            "suites": {}, "flaky": False, "attempts": 0, "seconds": 0.0}


def copy_state(copy):
    """The copy's `git status`, or None when git fails (no copy, no .git): that is dirty."""
    out = subprocess.run(["git", "-C", str(copy), "status", "--porcelain", "--ignored"],
                         capture_output=True, text=True)
    return out.stdout if out.returncode == 0 else None


class Runner:
    """Runs mutants in this process's copy, one baseline per suite and session, and gives a
    survivor a second run."""

    def __init__(self, args, sha, command, check_argv=None):
        self.args, self.sha, self.command = args, sha, command
        self.check_argv = check_argv
        self.check_silent = False
        self.copy = None
        self.baselines = {}

    def ensure_copy(self):
        if self.copy is None:
            self.copy = build_copy(self.args.repo, self.sha, self.args.copy_root, self.command)
        return self.copy

    def run(self, suite, timeout):
        """One run of a suite, or, with a rule check command, of the pseudo-suite `check`."""
        if self.check_argv is not None and suite == CHECK_SUITE:
            run = run_check(self.copy, [a.replace("{copy}", str(self.copy)) for a in self.check_argv],
                            timeout, self.args.lock)
            return synthesize_check(run) if self.check_silent and suite in self.baselines else run
        return run_suite(self.copy, suite, timeout, self.args.lock)

    def baseline(self, suite):
        if suite not in self.baselines:
            self.ensure_copy()
            run = self.run(suite, BASELINE_TIMEOUT)
            if self.check_argv is not None and suite == CHECK_SUITE:
                # Only a checker whose baseline printed no assertions gets an invented one.
                self.check_silent = not run.passed and not run.failed and not run.timed_out
                if self.check_silent:
                    synthesize_check(run)
            self.baselines[suite] = run
        return self.baselines[suite]

    def attempt(self, suite, baseline):
        timeout = max(self.args.timeout_floor, 3 * baseline.seconds)
        first = run_result(baseline, self.run(suite, timeout))
        first.update(attempts=1, flaky=False)
        if first["verdict"] != "survived":
            return first
        if not Path(self.copy).is_dir():
            first.update(rerun="skipped")
            return first
        second = run_result(baseline, self.run(suite, timeout))
        total = round(first["seconds"] + second["seconds"], 3)
        if second["verdict"] == "killed":
            second.update(attempts=2, flaky=True, seconds=total)
            return second
        first.update(attempts=2, rerun=second["verdict"], seconds=total)
        return first

    def mutate(self, mutant, suites):
        """Per-suite results of one mutant, or None when it no longer applies (stale)."""
        copy = self.ensure_copy()
        target = inside_copy(copy, mutant["file"])
        if not target.is_file():
            return None
        mutated = mutators.apply(target.read_text(), mutant)
        if mutated is None:
            return None
        base = {s: self.baseline(s) for s in suites}
        results = {s: red_result(b) for s, b in base.items() if not baseline_ok(b)}
        live = [s for s in suites if s not in results]
        if live:
            before = copy_state(copy)
            SESSION.apply_text(target, mutated)
            try:
                for suite in live:
                    results[suite] = self.attempt(suite, base[suite])
            finally:
                SESSION.restore_files()
            after = copy_state(copy)
            if after is None or after != before:
                self.rebuild(mutant["id"])
        return {s: results[s] for s in suites}

    def rebuild(self, mutant_id):
        """A mutant's run wrote or deleted something inside the copy: start the next one from a
        fresh copy, which is identical to the original, so the session's baselines still hold."""
        SESSION.copies.remove(self.copy)
        self.copy = build_copy(self.args.repo, self.sha, self.args.copy_root, self.command)
        print(f"copy rebuilt after {mutant_id}", flush=True)


def rec_key(rec):
    return (rec.get("candidate"), rec["id"])


def final_records(store, kind):
    return {rec_key(r): r for r in store.records(kind)}


def is_final(done, key):
    """A record is not final while its mutant, or any suite it was asked to run in, was
    baseline-red: the next session retries it (R10)."""
    rec = done.get(key)
    return rec is not None and "baseline-red" not in (rec["verdict"], *rec.get("suites", {}).values())


def mutant_head(m):
    return {k: m[k] for k in ("id", "kind", "file", "op", "line", "before", "after")}


def hold_state(state, command):
    """One run per state and command: the lock is released at exit with the process."""
    lock = Lock(Path(state) / f"{command}.lock")
    if not lock.try_acquire():
        die(f"another {command} run holds {state}")
    SESSION.locks.append(lock)


class Budget:
    def __init__(self, minutes):
        self.deadline = None if minutes is None else time.monotonic() + minutes * 60

    def spent(self):
        return self.deadline is not None and time.monotonic() >= self.deadline


def cmd_sample(args):
    sha = preflight(args, bind=True)
    source = Path(args.sample_from or args.state) / "sample.jsonl"
    if not source.exists():
        die(f"no frozen sample at {source}: run plan first")
    rows = read_jsonl(source)
    files = list(dict.fromkeys(r["file"] for r in rows))
    if args.only:
        for f in args.only:
            if f not in files:
                die(f"{f} is not in the sample")
        files = [f for f in files if f in args.only]
    if args.killed_in:
        before = final_records(Store(args.killed_in), "sample")
        if not before:
            die(f"{args.killed_in} has no sample runs for --killed-in")
        killed = {k[1] for k, r in before.items() if is_final(before, k) and r["verdict"] == "killed"}
        rows = [r for r in rows if r["id"] in killed]
    hold_state(args.state, "sample")
    store = Store(args.state)
    done = final_records(store, "sample")
    budget, runner = Budget(args.max_minutes), Runner(args, sha, "sample")
    for file in files:
        mine = [r for r in rows if r["file"] == file]
        attempted = 0
        for row in mine:
            if is_final(done, (None, row["id"])):
                continue
            if budget.spent():
                break
            results = runner.mutate(row, [row["suite"]])
            outcome = stale_outcome() if results is None else combine(results)
            rec = {**mutant_head(row), "suite": row["suite"], **outcome}
            store.append("sample", rec)
            done[(None, row["id"])] = rec
            attempted += 1
        if attempted:
            have = [done[(None, r["id"])] for r in mine if is_final(done, (None, r["id"]))]
            count = lambda v: sum(1 for r in have if r["verdict"] == v)
            red = sum(1 for r in mine if (None, r["id"]) in done and not is_final(done, (None, r["id"])))
            print(f"[sample] {file}: {len(have)}/{len(mine)} (killed {count('killed')}, "
                  f"survived {count('survived')}, inconclusive {count('inconclusive')}, "
                  f"baseline-red {red})", flush=True)
    print(f"remaining: {sum(1 for r in rows if r['file'] in files and not is_final(done, (None, r['id'])))}")


def load_manifest(path):
    entries, seen = [], set()
    for n, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            die(f"{path}:{n}: not JSON")
        for key in ("candidate", "suite", "labels", "claim", "mutants"):
            if key not in entry:
                die(f"{path}:{n}: candidate lacks {key}")
        if entry["candidate"] in seen:
            die(f"{path}:{n}: candidate {entry['candidate']} appears twice")
        seen.add(entry["candidate"])
        entries.append(entry)
    return entries


def build_targeted(args, sha, entries):
    """candidate name -> its mutants. Exits 2 naming a candidate whose find is not unique."""
    texts, built = {}, {}
    for entry in entries:
        name, mutants = entry["candidate"], []
        for spec in entry["mutants"]:
            file = spec["file"]
            if file not in texts:
                texts[file] = git_show(args.repo, sha, file)
            if texts[file] is None:
                die(f"candidate {name}: no such file {file} at {sha[:12]}")
            mutant, found = mutators.targeted_mutant(file, texts[file], spec["find"], spec["replace"],
                                                     spec.get("line"))
            if mutant is None:
                where = f" on line {spec['line']}" if spec.get("line") else ""
                die(f"candidate {name}: {spec['find']!r} occurs {found} times in {file}{where}, "
                    f"want exactly 1")
            mutants.append(mutant)
        built[name] = mutants
    return built


def suite_status(row):
    """ok, gated or red, from an inventory row."""
    if row["seconds"] is None:
        return "gated"
    return "red" if row["rc"] != 0 or row["failed"] else "ok"


def check_targeted_suites(args, sha, entries, built, subjects):
    """Exit 2 before any run when a candidate's own suite is missing, gated or red, or when a
    duplicate candidate's loader suite is red: its records would stay open for ever."""
    inventory = load_inventory(args.state)
    for entry in entries:
        name, suite = entry["candidate"], entry["suite"]
        text = git_show(args.repo, sha, f"tests/{suite}.test.sh")
        if text is None:
            die(f"candidate {name}: no such suite {suite} at {sha[:12]}")
        required = header_of(text, "test-requires")
        if required not in ("", "heavy"):
            die(f"candidate {name}: suite {suite} needs {required}, so it is never mutated")
        if suite in inventory and suite_status(inventory[suite]) == "red":
            die(f"candidate {name}: suite {suite} is red in the inventory (copy-red)")
        if entry["claim"] == "duplicate":
            for mutant in built[name]:
                for loader in subjects.get(mutant["file"], {"loaded_by": []})["loaded_by"]:
                    if loader in inventory and suite_status(inventory[loader]) == "red":
                        die(f"candidate {name}: loader suite {loader} is red in the inventory (copy-red)")


def runnable_suites(copy, names):
    keep = []
    for name in dict.fromkeys(names):
        script = Path(copy) / "tests" / f"{name}.test.sh"
        if script.is_file() and header(script, "test-requires") in ("", "heavy"):
            keep.append(name)
    return keep


def cmd_targeted(args):
    sha = preflight(args, bind=True)
    entries = load_manifest(args.manifest)
    built = build_targeted(args, sha, entries)
    subjects = {r["file"]: r for r in load_subjects(args.subjects, args.subjects_explicit)}
    check_targeted_suites(args, sha, entries, built, subjects)
    hold_state(args.state, "targeted")
    store = Store(args.state)
    done = final_records(store, "targeted")
    budget, runner = Budget(args.max_minutes), Runner(args, sha, "targeted")
    for entry in entries:
        name, mutants = entry["candidate"], built[entry["candidate"]]
        attempted = 0
        for mutant in mutants:
            if is_final(done, (name, mutant["id"])):
                continue
            if budget.spent():
                break
            wanted = [entry["suite"]]
            if entry["claim"] == "duplicate":
                wanted += subjects.get(mutant["file"], {"loaded_by": []})["loaded_by"]
            suites = runnable_suites(runner.ensure_copy(), wanted)
            if entry["suite"] not in suites:
                die(f"candidate {name}: suite {entry['suite']} cannot be mutated here")
            results = runner.mutate(mutant, suites)
            outcome = stale_outcome() if results is None else combine(results)
            rec = {**mutant_head(mutant), "candidate": name, "suite": entry["suite"],
                   "claim": entry["claim"], "labels": qualified(entry["suite"], entry["labels"]),
                   **outcome}
            store.append("targeted", rec)
            done[(name, mutant["id"])] = rec
            attempted += 1
        if attempted:
            have = sum(1 for m in mutants if is_final(done, (name, m["id"])))
            print(f"[targeted] {name}: {have}/{len(mutants)}", flush=True)
        if budget.spent():
            break
    print(f"remaining: {sum(1 for e in entries for m in built[e['candidate']] if not is_final(done, (e['candidate'], m['id'])))}")


def cmd_pins(args):
    path = Path(args.suite_file)
    if not path.is_file():
        die(f"no such suite file: {path}")
    try:
        found = rules.pins(path.read_text())
    except rules.PinError as err:
        print(f"{path}: {err}", file=sys.stderr)
        sys.exit(1)
    for row in found:
        print("\t".join(row))


def load_rules(path):
    """Rows of a rules TSV: id, file, anchor, safety, terms, note (the note may be left off)."""
    out, seen = [], set()
    for n, line in enumerate(Path(path).read_text().split("\n"), 1):
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) not in (5, 6):
            die(f"{path}:{n}: want id, file, anchor, safety, terms, note; got {len(cols)} columns")
        rid, file, anchor, safety, terms = cols[:5]
        if not rid or not file or not anchor.strip() or rid in seen:
            die(f"{path}:{n}: needs a unique id, a file and an anchor")
        if safety not in ("yes", "no", "?"):
            die(f"{path}:{n}: safety must be yes, no or ?, got {safety!r}")
        seen.add(rid)
        out.append({"id": rid, "file": file, "anchor": anchor, "safety": safety,
                    "terms": [t for t in terms.split(";") if t and t != "-"],
                    "note": cols[5] if len(cols) == 6 else ""})
    return out


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def resolve_check_cmd(check_cmd):
    """The check command's argv with every argument that names an existing file made absolute, so
    that it is hashed and run as the same file from any directory. Exits 2 when argv[0] is neither."""
    argv = shlex.split(check_cmd)
    if not argv:
        die("empty check command")
    argv = [os.path.abspath(a) if os.path.isfile(a) else a for a in argv]
    if not os.path.isfile(argv[0]) and shutil.which(argv[0]) is None:
        die(f"check command not found: {check_cmd}")
    return argv


def bind_rules(args, check_argv):
    """The state keeps one rule set and one checker: resumed results belong to both."""
    binding = {"tsv": sha256_file(args.rules_tsv), "check_cmd": shlex.join(check_argv) if check_argv else "",
               "files": {a: sha256_file(a) for a in check_argv if os.path.isfile(a)}}
    store = Store(args.state)
    meta = store.meta()
    if "rules" not in meta:
        store.bind(meta["sha"], rules=binding)
    elif meta["rules"] != binding:
        die("state is bound to another rule set or check; use another --state")


def rule_suites(args, sha, row, check_argv, inventory, subjects):
    """The suites a rule's mutants run in: the checker, or the runnable suites that load the file."""
    if check_argv is not None:
        return [CHECK_SUITE]
    if row["file"] not in subjects:
        die(f"rule {row['id']}: {row['file']} has no row in the subject map")
    keep = []
    for name in subjects[row["file"]]["loaded_by"]:
        text = git_show(args.repo, sha, f"tests/{name}.test.sh")
        required = header_of(text or "", "test-requires")
        if text is None or required not in ("", "heavy"):
            continue
        if name in inventory and suite_status(inventory[name]) == "red":
            die(f"rule {row['id']}: loader suite {name} is red in the inventory (copy-red)")
        keep.append(name)
    if not keep:
        die(f"rule {row['id']}: no runnable suite loads {row['file']}")
    return keep


def cmd_rules(args):
    rows = load_rules(args.rules_tsv)
    check_argv = resolve_check_cmd(args.check_cmd) if args.check_cmd else None
    sha = preflight(args, bind=True)
    subjects = {r["file"]: r for r in load_subjects(args.subjects, args.subjects_explicit)}
    inventory = load_inventory(args.state)
    plan, suites = [], {}
    for row in rows:
        text = git_show(args.repo, sha, row["file"])
        if text is None:
            die(f"rule {row['id']}: no such file {row['file']} at {sha[:12]}")
        mutants, info = rules.rule_plan(row["file"], text, row["id"], row["anchor"])
        if info["unparsed"]:
            print(f"unparsed-list: {row['id']}", file=sys.stderr)
        if mutants:
            suites[row["id"]] = rule_suites(args, sha, row, check_argv, inventory, subjects)
        plan.append({**row, "missing": not info["found"], "ambiguous": info["ambiguous"],
                     "unparsed": info["unparsed"],
                     "mutants": [{**mutant_head(m), "rule": m["rule"], "item": m["item"]} for m in mutants],
                     "_full": mutants})
    hold_state(args.state, "rules")
    bind_rules(args, check_argv or [])
    write_atomic(Path(args.state) / "rules.jsonl",
                 "".join(json.dumps({k: v for k, v in r.items() if k != "_full"}) + "\n" for r in plan))
    store = Store(args.state)
    done = final_records(store, "rules")
    budget, runner = Budget(args.max_minutes), Runner(args, sha, "rules", check_argv)
    for row in plan:
        attempted = 0
        for mutant in row["_full"]:
            if is_final(done, (None, mutant["id"])):
                continue
            if budget.spent():
                break
            results = runner.mutate(mutant, suites[row["id"]])
            outcome = stale_outcome() if results is None else combine(results)
            rec = {**mutant_head(mutant), "rule": row["id"], "item": mutant["item"], **outcome}
            store.append("rules", rec)
            done[(None, mutant["id"])] = rec
            attempted += 1
        if attempted:
            mine = [done[(None, m["id"])] for m in row["_full"] if is_final(done, (None, m["id"]))]
            count = lambda v: sum(1 for r in mine if r["verdict"] == v)
            red = sum(1 for m in row["_full"] if (None, m["id"]) in done and not is_final(done, (None, m["id"])))
            print(f"[rules] {row['id']}: {len(mine)}/{len(row['_full'])} (killed {count('killed')}, "
                  f"survived {count('survived')}, inconclusive {count('inconclusive')}, "
                  f"baseline-red {red})", flush=True)
    missing = [r["id"] for r in plan if r["missing"]]
    ambiguous = [r["id"] for r in plan if r["ambiguous"]]
    for rid in missing:
        print(f"missing: {rid}")
    for rid in ambiguous:
        print(f"ambiguous: {rid}")
    print(f"remaining: {sum(1 for r in plan for m in r['_full'] if not is_final(done, (None, m['id'])))}")
    if missing or ambiguous:
        sys.exit(1)


def report_rules(args):
    path = Path(args.state) / "rules.jsonl"
    rows = read_jsonl(path) if path.exists() else []
    recs = final_records(Store(args.state), "rules")
    print("| rule | safety | mutants | killed | survivors |")
    print("|---|---|---|---|---|")
    for row in rows:
        if row["missing"] or row.get("ambiguous"):
            continue
        mine = [recs.get((None, m["id"])) for m in row["mutants"]]
        killed = sum(1 for r in mine if r and r["verdict"] == "killed")
        survivors = "; ".join(f"{r['op']}:{r['item']}".replace("|", "\\|")
                              for r in mine if r and r["verdict"] == "survived")
        print(f"| {row['id']} | {row['safety']} | {len(row['mutants'])} | {killed} | {survivors or '-'} |")
    missing = [row["id"] for row in rows if row["missing"]]
    ambiguous = [row["id"] for row in rows if row.get("ambiguous")]
    unparsed = [(row["id"], row["unparsed"]) for row in rows if row.get("unparsed")]
    if missing or ambiguous or unparsed:
        print()
    for rid in missing:
        print(f"missing: {rid}")
    for rid in ambiguous:
        print(f"ambiguous: {rid}")
    if unparsed:
        print(f"unparsed lists: {sum(n for _, n in unparsed)} in {len(unparsed)} rules")
        for rid, n in unparsed:
            print(f"unparsed-list: {rid} ({n})")


def candidate_verdict(suite, labels, records):
    """evidenced, unique, mis-targeted or inconclusive, from a candidate's mutant records. A
    mutant only the candidate's own labels killed stays undecided while another requested suite
    gave no verdict (baseline-red) or an inconclusive one."""
    labels, mis, unclear, unique = set(labels), False, False, False
    for rec in records:
        suites = rec["suites"]
        killers = set(rec["killers"])
        if not labels & killers:
            if suites.get(suite) in ("survived", "killed"):
                mis = True
            else:
                unclear = True
        elif not killers - labels:
            if any(v in ("baseline-red", "inconclusive") for k, v in suites.items() if k != suite):
                unclear = True
            else:
                unique = True
    if mis:
        return "mis-targeted"
    if unclear or not records:
        return "inconclusive"
    return "unique" if unique else "evidenced"


def mark(rec, killer):
    return killer + ("*" if killer in rec.get("via_detail", []) else "")


def report_kills(args):
    store, state = Store(args.state), Path(args.state)
    recs = final_records(store, "sample")
    by_file = {}
    for rec in recs.values():
        by_file.setdefault(rec["file"], []).append(rec)
    sampled = {}
    if (state / "sample.jsonl").exists():
        for row in read_jsonl(state / "sample.jsonl"):
            sampled[row["file"]] = sampled.get(row["file"], 0) + 1
    print("| file | sampled | killed | flaky | survived | inconclusive | baseline-red | stale | "
          "via_detail | kill rate |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for file in sorted(set(by_file) | set(sampled)):
        have = by_file.get(file, [])
        count = lambda v: sum(1 for r in have if r["verdict"] == v)
        killed, survived = count("killed"), count("survived")
        flaky = sum(1 for r in have if r["verdict"] == "killed" and r.get("flaky"))
        via = sum(1 for r in have if r["verdict"] == "killed" and r.get("via_detail"))
        rate = f"{100 * killed / (killed + survived):.1f}%" if killed + survived else "-"
        print(f"| {file} | {sampled.get(file, len(have))} | {killed} | {flaky} | {survived} | "
              f"{count('inconclusive')} | {count('baseline-red')} | {count('stale')} | {via} | {rate} |")
    killed_by = {}
    for rec in recs.values():
        if rec["verdict"] == "killed":
            for killer in rec["killers"]:
                suite, label = killer.split("::", 1)
                killed_by.setdefault((suite, label), []).append(rec["id"])
    inventory = load_inventory(args.state)
    for suite in {r["suite"] for r in recs.values()}:
        for label in inventory.get(suite, {}).get("labels", []):
            killed_by.setdefault((suite, label), [])
    print()
    print("| suite | assertion | kills | mutants |")
    print("|---|---|---|---|")
    for (suite, label), ids in sorted(killed_by.items()):
        print(f"| {suite} | {label} | {len(ids)} | {' '.join(sorted(ids)) or '-'} |")


def report_gaps(args):
    recs = final_records(Store(args.state), "sample")
    print("| file:line | operator | change | mutant |")
    print("|---|---|---|---|")
    for rec in sorted((r for r in recs.values() if r["verdict"] == "survived"),
                      key=lambda r: (r["file"], r["line"], r["id"])):
        print(f"| {rec['file']}:{rec['line']} | {rec['op']} | {rec['before']} → {rec['after']} | {rec['id']} |")


def report_targeted(args):
    by_candidate = {}
    for rec in final_records(Store(args.state), "targeted").values():
        by_candidate.setdefault(rec["candidate"], []).append(rec)
    print("| candidate | verdict | mutant | outcome | killers |")
    print("|---|---|---|---|---|")
    for name in sorted(by_candidate):
        recs = sorted(by_candidate[name], key=lambda r: (r["file"], r["line"], r["id"]))
        verdict = candidate_verdict(recs[0]["suite"], recs[0]["labels"], recs)
        for rec in recs:
            killers = "; ".join(mark(rec, k) for k in rec["killers"]) or "-"
            print(f"| {name} | {verdict} | {rec['id']} {rec['file']}:{rec['line']} | "
                  f"{rec['verdict']} | {killers} |")
    print("* attributed through failure detail (R8)")


def report_compare(args):
    store_kind = KINDS[args.kind]
    theirs = final_records(Store(args.compare), store_kind)
    here = {k: r for k, r in final_records(Store(args.state), store_kind).items() if is_final({k: r}, k)}
    files = set(args.only) if args.only else {r["file"] for r in here.values()}
    lost, not_run = [], []
    for key, rec in theirs.items():
        if rec["verdict"] != "killed" or rec["file"] not in files:
            continue
        mine = here.get(key)
        if mine is None:
            not_run.append(rec)
        elif mine["verdict"] != "killed":
            lost.append(rec)
    for title, recs in (("lost", lost), ("not run", not_run)):
        print(f"{title}: {len(recs)}")
        for rec in sorted(recs, key=lambda r: (r["file"], r["line"], r["id"])):
            print(f"- {rec['id']} {rec['file']}:{rec['line']} {rec['op']} {rec['before']} → {rec['after']}")


def cmd_report(args):
    if args.compare and not args.kind:
        die("--compare needs --kind code|targeted|rule")
    {"inventory": report_inventory, "kills": report_kills, "gaps": report_gaps,
     "targeted": report_targeted, "rules": report_rules}[args.section](args)
    if args.compare:
        print()
        report_compare(args)


CLASSIFICATION_COLUMNS = ["suite", "test", "labels", "kind", "duplicate_of", "verdict", "merge_with",
                          "evidence", "safety", "note"]


def read_classification(path):
    lines = Path(path).read_text().split("\n")
    if lines[0].split("\t") != CLASSIFICATION_COLUMNS:
        die(f"{path}: header must be {', '.join(CLASSIFICATION_COLUMNS)}")
    rows = []
    for n, line in enumerate(lines[1:], 2):
        if not line.strip():
            continue
        cols = line.split("\t")
        if len(cols) > len(CLASSIFICATION_COLUMNS):
            die(f"{path}:{n}: {len(cols)} columns, want {len(CLASSIFICATION_COLUMNS)}")
        row = dict(zip(CLASSIFICATION_COLUMNS, cols + [""] * (len(CLASSIFICATION_COLUMNS) - len(cols))))
        for key in ("labels", "duplicate_of", "merge_with"):
            row[key] = [x for x in row[key].split(" | ") if x and x != "-"]
        rows.append(row)
    return rows


def cmd_accept(args):
    rows = [r for r in read_classification(args.classification) if r["verdict"] in ("delete", "merge")]
    entries = load_manifest(args.manifest)
    sha = state_sha(args)
    built = build_targeted(args, sha, entries)
    records = final_records(Store(args.state), "targeted")
    inventory = load_inventory(args.state)
    for row in rows:
        where = f"row {row['suite']}:{row['test']}"
        if row["evidence"] not in ("class", "targeted"):
            die(f"{where}: evidence must be class or targeted, got {row['evidence']!r}")
        refs = [(row["suite"], label) for label in row["labels"]]
        refs += [tuple(ref.split("::", 1)) for ref in row["duplicate_of"] + row["merge_with"] if "::" in ref]
        for suite, label in refs:
            if label not in inventory.get(suite, {}).get("labels", []):
                die(f"{where}: {label!r} is not a baseline label of {suite}")

    def saved(row):
        info = inventory.get(row["suite"])
        if not info or not info.get("seconds") or not info.get("assertions"):
            return 0.0
        return info["seconds"] * len(row["labels"]) / info["assertions"]

    def first_line(row):
        return int(re.match(r"\d+", row["test"]).group(0)) if re.match(r"\d+", row["test"]) else 0

    ranked = sorted(rows, key=lambda r: (-saved(r), r["suite"], first_line(r)))
    by_name = {e["candidate"]: e for e in entries}
    by_labels = {(e["suite"], tuple(e["labels"])): e for e in entries}
    accepted, removed = [], set()
    print("| candidate | est. seconds saved | result |")
    print("|---|---|---|")
    for row in ranked:
        name = f"{row['suite']}:{row['test']}"
        labels = set(qualified(row["suite"], row["labels"]))
        entry = by_name.get(name) or by_labels.get((row["suite"], tuple(row["labels"])))
        mutants = []
        reason = None
        if row["evidence"] == "targeted":
            recs = ([records[(entry["candidate"], m["id"])]
                     if is_final(records, (entry["candidate"], m["id"])) else None
                     for m in built[entry["candidate"]]] if entry else [])
            if (not entry or not recs or None in recs
                    or candidate_verdict(entry["suite"], qualified(entry["suite"], entry["labels"]),
                                         recs) != "evidenced"):
                reason = "not evidenced"
            else:
                mutants = [(r["id"], set(r["killers"])) for r in recs]
        elif row["kind"] == "duplicate":
            reason = "duplicate needs targeted evidence"
        elif row["safety"] == "yes" or (row["suite"] in SAFETY_SUITES and row["suite"] != "agent-instructions"):
            reason = "class evidence in a safety suite"
        if reason is None:
            gone = removed | labels
            for _, group in accepted + [(name, mutants)]:
                broken = next((mid for mid, killers in group if not killers - gone), None)
                if broken:
                    reason = f"would leave {broken} without a killer"
                    break
        if reason is None:
            accepted.append((name, mutants))
            removed |= labels
        print(f"| {name} | {saved(row):.1f} | {'accepted' if reason is None else 'rejected: ' + reason} |")


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
    mu = sub.add_parser("mutants")
    mu.add_argument("file")
    mu.set_defaults(func=cmd_mutants)
    pl = sub.add_parser("plan")
    pl.set_defaults(func=cmd_plan)
    sa = sub.add_parser("sample")
    sa.add_argument("--max-minutes", type=float)
    sa.add_argument("--only", nargs="+", default=[])
    sa.add_argument("--sample-from")
    sa.add_argument("--killed-in", help="run only the mutants this state's sample runs killed")
    sa.set_defaults(func=cmd_sample)
    ta = sub.add_parser("targeted")
    ta.add_argument("--max-minutes", type=float)
    ta.add_argument("manifest")
    ta.set_defaults(func=cmd_targeted)
    pn = sub.add_parser("pins")
    pn.add_argument("suite_file")
    pn.set_defaults(func=cmd_pins)
    ru = sub.add_parser("rules")
    ru.add_argument("--max-minutes", type=float)
    ru.add_argument("--check-cmd", help="a command to run instead of the loader suites; arguments that name "
                    "a file are resolved against the harness's cwd, so paths inside the copy must use {copy}")
    ru.add_argument("rules_tsv")
    ru.set_defaults(func=cmd_rules)
    rep = sub.add_parser("report")
    rep.add_argument("--section", required=True, choices=["inventory", "kills", "gaps", "targeted", "rules"])
    rep.add_argument("--compare")
    rep.add_argument("--kind", choices=sorted(KINDS))
    rep.add_argument("--only", nargs="+", default=[])
    rep.set_defaults(func=cmd_report)
    ac = sub.add_parser("accept")
    ac.add_argument("classification")
    ac.add_argument("manifest")
    ac.set_defaults(func=cmd_accept)
    p.set_defaults(harness_dir=here)
    return p


def on_signal(signum, _frame):
    sys.exit(128 + signum)


def main(argv=None):
    args = parser().parse_args(argv)
    sys.stdout.reconfigure(encoding="utf-8")
    if args.repo is None:
        top = subprocess.run(["git", "-C", str(args.harness_dir), "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True)
        if top.returncode != 0:
            die("cannot find the repository; pass --repo")
        args.repo = top.stdout.strip()
    args.state = args.state or os.path.join(args.repo, ".superpowers", "test-audit")
    args.subjects_explicit = args.subjects is not None
    args.subjects = args.subjects or str(args.harness_dir / "subjects.tsv")
    for sig in STOP_SIGNALS:
        signal.signal(sig, on_signal)
    try:
        args.func(args)
    finally:
        SESSION.cleanup()
    return 0


if __name__ == "__main__":
    sys.exit(main())
