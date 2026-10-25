#!/usr/bin/env bash
# Tests for .scripts/xreview-replay.py: the harness that measures each review-packet switch
# (framing, omit_plans, delta, fit) against today's packets on past reviews (spec
# docs/superpowers/specs/2026-10-25-xreview-review-packets-design.md, section 5).
#
# One fixture case, all of it fake: a git repository with a plan and three review rounds, a
# ledger with their receipts, rollouts that carry the historical answers, and an xreview-rpc on
# XREVIEW_REPLAY_RPC that answers like the daemon without one. RP1 cases, RP2 the arms' packets
# (dry run), RP3 blind judge inputs, RP4 the pass bar, RP5 an interrupted run archives its
# threads, RP6 a truncated run is incomplete and never passed. The checks run in one python3
# process and print PASS:/FAIL: lines; this wrapper counts them.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$SRC/.scripts/xreview-replay.py"
MODULE="$SRC/dot_claude/xreview-packet.py"
LEDGER="$SRC/dot_claude/xreview-ledger.py"
CONF="$SRC/dot_config/xreview"
for f in "$HARNESS" "$MODULE" "$LEDGER" "$CONF/reviewer.md" "$CONF/reviewer-framing.md" \
         "$CONF/findings.schema.json" "$CONF/findings.framed.schema.json"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xrreplay.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$ROOT"
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
  > "$GIT_CONFIG_GLOBAL"
export T_HARNESS="$HARNESS" T_MODULE="$MODULE" T_LEDGER="$LEDGER" T_CONF="$CONF" T_ROOT="$ROOT"

out="$(/usr/bin/python3 -I - <<'PY'
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
import time

HARNESS, MODULE, LEDGER, CONF, ROOT = (os.environ[k] for k in
                                       ("T_HARNESS", "T_MODULE", "T_LEDGER", "T_CONF", "T_ROOT"))
os.environ["XREVIEW_LEDGER"] = LEDGER


def ok(name, cond, got=""):
    print("  PASS: " + name if cond else "  FAIL: {}\n    | got: {}".format(name, str(got)[:400]))


def is_(name, got, want):
    ok(name, got == want, repr(got) + " want " + repr(want))


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


XP = load(MODULE, "xp")
LD = XP._ledger()


def git(repo, *args):
    return subprocess.run(["git", "-C", repo] + list(args), check=True, capture_output=True).stdout.decode().strip()


def put(repo, path, text):
    full = os.path.join(repo, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(text)


def commit(repo, msg):
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", msg)
    return git(repo, "rev-parse", "HEAD")


def jl(path):
    with open(path) as f:
        return json.load(f)


def wr(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(data if isinstance(data, str) else json.dumps(data))
    return path


# ------------------------------------------------------------------ the fixture
XDG, CODEX, FAKE = (os.path.join(ROOT, d) for d in ("xdg", "codex", "fake"))
repo = os.path.join(ROOT, "repo")
os.makedirs(repo)
git(repo, "init", "-q")
put(repo, "seed.txt", "seed\n")
c0 = commit(repo, "seed")
git(repo, "checkout", "-q", "-b", "feat")
PLAN = "docs/superpowers/plans/2026-10-25-x.md"
put(repo, PLAN, "# Plan\n- [ ] task one\n- [ ] task two\n")
p1 = commit(repo, "plan")
put(repo, "lib.py", "def f(x):\n    return x + 2\n")
put(repo, PLAN, "# Plan\n- [x] task one\n- [ ] task two\n")
c1 = commit(repo, "round 1")
put(repo, "lib.py", "def f(x):\n    return x + 1\n")
put(repo, PLAN, "# Plan\n- [x] task one\n- [x] task two\n")
c2 = commit(repo, "round 2")
put(repo, "lib.py", "def f(x):\n    return x + 1  # checked\n")
c3 = commit(repo, "round 3")
common = LD.common_dir(repo)
RANGE = "main...feat"


def target(tip, base=c0):
    return {"repo": common, "dest": "main", "dest_ref": "main", "branch": "feat", "range": RANGE,
            "base": base, "tip": tip, "full": True, "fingerprint": LD.fingerprint(repo, base, tip)}


def receipt(nonce, n, checkpoint, thread, turn, tgt, verdict):
    return {"v": 2, "kind": "receipt", "nonce": nonce,
            "dispatched_at": "2026-10-20T10:{:02d}:00.000000Z".format(n), "checkpoint": checkpoint,
            "verdict": verdict, "findings": 0, "thread": thread, "turn": turn, "tier": "", "targets": [tgt]}


T, TP = "thT", "thTP"
R = [receipt("xr-1-plan", 1, "plan", TP, "tuP", target(p1), "approve"),
     receipt("xr-2-r1", 2, "pre-merge", T, "tu1", target(c1), "changes"),
     receipt("xr-3-r2", 3, "pre-merge", T, "tu2", target(c2), "changes"),
     receipt("xr-4-r3", 4, "pre-merge", T, "tu3", target(c3), "approve")]
ldir = os.path.join(XDG, "xreview", "ledgers", LD.ledger_key(common))
wr(os.path.join(ldir, "reviews.jsonl"), "".join(json.dumps(e) + "\n" for e in R))
wr(os.path.join(ldir, "repo"), common + "\n")

F1 = {"verdict": "changes", "findings": [
    {"severity": "P1", "file": "lib.py", "line": 2, "summary": "f adds 2, not 1", "failure_scenario": "f(1) is 3"},
    {"severity": "P3", "file": "lib.py", "line": 1, "summary": "nit about naming", "failure_scenario": "none"}]}
F2 = {"verdict": "changes", "findings": [
    {"severity": "P2", "file": "lib.py", "line": 2, "summary": "no comment on the offset", "failure_scenario": "readers guess"}]}
APPROVE = {"verdict": "approve", "findings": []}


def rollout(home, thread, turns, window=200000, stamp="2026-10-20T10-00-00", sub="sessions/2026/10/20"):
    """turns: [(turn id, context before it, answer, compacted)]."""
    recs = []
    total = 0
    for turn, ctx, answer, compacted in turns:
        if ctx is not None:
            recs.append({"type": "event_msg", "payload": {"type": "token_count", "info": {
                "total_token_usage": {"total_tokens": total}, "last_token_usage": {"total_tokens": ctx},
                "model_context_window": window}}})
        recs.append({"type": "event_msg", "payload": {"type": "task_started", "turn_id": turn, "model_context_window": window}})
        recs.append({"type": "turn_context", "payload": {"turn_id": turn, "model": "m-1", "effort": "high"}})
        if compacted:
            recs.append({"type": "compacted", "payload": {"message": ""}})
        total += 1000
        recs.append({"type": "event_msg", "payload": {"type": "token_count", "info": {
            "total_token_usage": {"total_tokens": total}, "last_token_usage": {"total_tokens": 1000},
            "model_context_window": window}}})
        recs.append({"type": "event_msg", "payload": {"type": "task_complete", "turn_id": turn,
                                                       "last_agent_message": json.dumps(answer)}})
    wr(os.path.join(home, sub, "rollout-{}-{}.jsonl".format(stamp, thread)), "".join(json.dumps(r) + "\n" for r in recs))


rollout(CODEX, TP, [("tuP", None, APPROVE, False)])
rollout(CODEX, T, [("tu1", None, F1, False), ("tu2", 175000, F2, False), ("tu3", 120000, APPROVE, False)])

# ------------------------------------------------------------------ the fake daemon client
FAKE_RPC = r'''#!/usr/bin/python3
import fcntl, json, os, subprocess, sys, time
S = os.environ["FAKE_STATE"]
CODEX = os.environ["CODEX_HOME"]
args = sys.argv[1:]
cmd = args[0]


def opt(name):
    return args[args.index(name) + 1] if name in args else None


def locked(fn):
    os.makedirs(S, exist_ok=True)
    with open(os.path.join(S, "lock"), "a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        return fn()


def state():
    try:
        return json.load(open(os.path.join(S, "state.json")))
    except (OSError, ValueError):
        return {"n": 0, "archived": ["thT"], "cum": {}, "flight": 0, "max": 0}


def save(st):
    json.dump(st, open(os.path.join(S, "state.json"), "w"))


def log(**kw):
    with open(os.path.join(S, "calls.log"), "a") as f:
        f.write(json.dumps(dict(kw, cmd=cmd, args=args)) + "\n")


def new_id(st, prefix):
    st["n"] += 1
    return "{}{}x{}".format(prefix, os.path.basename(S), st["n"])


def rollout(thread, turn, answer, cum):
    recs = [{"type": "event_msg", "payload": {"type": "task_started", "turn_id": turn, "model_context_window": 200000}},
            {"type": "turn_context", "payload": {"turn_id": turn, "model": "fake-model", "effort": "high"}},
            {"type": "event_msg", "payload": {"type": "token_count", "info": {
                "total_token_usage": {"total_tokens": cum}, "last_token_usage": {"total_tokens": 1000},
                "model_context_window": 200000}}},
            {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": turn, "last_agent_message": json.dumps(answer)}}]
    d = os.path.join(CODEX, "sessions", "2026", "10", "25")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "rollout-2026-10-25T00-00-00-{}.jsonl".format(thread)), "a") as f:
        f.write("".join(json.dumps(r) + "\n" for r in recs))


def seed(thread, cum):
    d = os.path.join(CODEX, "sessions", "2026", "10", "25")
    os.makedirs(d, exist_ok=True)
    rec = {"type": "event_msg", "payload": {"type": "token_count", "info": {
        "total_token_usage": {"total_tokens": cum}, "last_token_usage": {"total_tokens": cum},
        "model_context_window": 200000}}}
    with open(os.path.join(d, "rollout-2026-10-25T00-00-00-{}.jsonl".format(thread)), "w") as f:
        f.write(json.dumps(rec) + "\n")


def archived_error(st, thread):
    if thread in st["archived"]:
        sys.stderr.write("xreview-rpc: thread/fork refused: thread {} is archived: unarchive it first\n".format(thread))
        return True
    return False


if cmd == "thread-start":
    if os.environ.get("FAKE_SLOW_START"):
        open(os.path.join(S, "starting"), "w").close()
        time.sleep(float(os.environ["FAKE_SLOW_START"]))
    def go():
        st = state(); t = new_id(st, "th"); save(st)
        log(thread=t, cwd=opt("--cwd")); print(t)
    locked(go)
elif cmd == "thread-fork":
    def go():
        st = state()
        if archived_error(st, opt("--thread")):
            log(refused=True); return 1
        t = new_id(st, "frk"); save(st); seed(t, 5000)
        log(thread=t, cwd=opt("--cwd"), last_turn=opt("--last-turn")); print(t); return 0
    sys.exit(locked(go))
elif cmd == "thread-turns":
    def go():
        st = state()
        if archived_error(st, opt("--thread")):
            return 1
        print(json.dumps({"turns": [{"id": i, "status": "completed", "compacted": False} for i in ("tu1", "tu2", "tu3")],
                          "thread_compactions": 0})); return 0
    sys.exit(locked(go))
elif cmd in ("thread-archive", "thread-unarchive"):
    def go():
        st = state(); t = opt("--thread")
        if cmd == "thread-archive":
            if t not in st["archived"]:
                st["archived"].append(t)
        elif t in st["archived"]:
            st["archived"].remove(t)
        save(st); log()
    locked(go)
elif cmd == "turn-start":
    def go():
        st = state(); turn = new_id(st, "tu-"); st["flight"] += 1; st["max"] = max(st["max"], st["flight"]); save(st)
        cwd = opt("--cwd")
        head = subprocess.run(["git", "-C", cwd, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        os.makedirs(os.path.join(S, "inputs"), exist_ok=True)
        open(os.path.join(S, "inputs", turn), "w").write(open(opt("--input")).read())
        refs = subprocess.run(["git", "-C", cwd, "for-each-ref", "--format=%(refname) %(objectname)"], capture_output=True, text=True).stdout.splitlines()
        rng = subprocess.run(["git", "-C", cwd, "rev-parse", os.environ.get("FAKE_RANGE", "main...feat")], capture_output=True, text=True).returncode
        log(thread=opt("--thread"), turn=turn, cwd=cwd, head=head, schema=os.path.basename(opt("--schema")), refs=refs, range_rc=rng)
        print(turn)
    locked(go)
elif cmd == "turn-wait":
    if os.environ.get("FAKE_HANG"):
        time.sleep(60)
    time.sleep(float(os.environ.get("FAKE_WAIT", "0.1")))
    thread, turn = opt("--thread"), opt("--turn")
    text = open(os.path.join(S, "inputs", turn)).read()
    shown = [l.split("  ")[-1] for l in text.splitlines() if l.startswith("  shown")]
    answer = {"verdict": "changes", "findings": [{"severity": "P1", "file": "lib.py", "line": 2,
                                                   "summary": "adds the wrong offset", "failure_scenario": "f(1) is 3"}]}
    if "reviewed_files" in open(opt("--schema")).read():
        answer["reviewed_files"] = shown
    def go():
        st = state()
        waits = st.setdefault("waits", {})
        if int(os.environ.get("FAKE_RC3", "0")) > waits.get(turn, 0):
            waits[turn] = waits.get(turn, 0) + 1; save(st)
            return None
        st["flight"] -= 1
        base = 5000 if thread.startswith("frk") and thread not in st["cum"] else 0
        cum = st["cum"].get(thread, base) + int(os.environ.get("FAKE_TOKENS", "1000"))
        st["cum"][thread] = cum; save(st)
        rollout(thread, turn, answer, cum)
        log(thread=thread, turn=turn)
        return answer
    answer = locked(go)
    if answer is None:
        sys.exit(3)
    if opt("--report"):
        json.dump({"turn": turn, "compacted": False}, open(opt("--report"), "w"))
    print(json.dumps(answer, indent=2))
    if os.environ.get("FAKE_RC4"):
        sys.exit(4)
else:
    sys.stderr.write("fake rpc: unknown command {}\n".format(cmd)); sys.exit(2)
'''
FAKE_BIN = wr(os.path.join(ROOT, "fake-rpc"), FAKE_RPC)
os.chmod(FAKE_BIN, 0o755)


def env_for(**extra):
    env = dict(os.environ, XDG_STATE_HOME=XDG, CODEX_HOME=CODEX, XREVIEW_REPLAY_RPC=FAKE_BIN, FAKE_STATE=FAKE)
    env.update(extra)
    return env


def harness(state, *args, **extra):
    return subprocess.run([HARNESS] + list(args) + ["--state", state], capture_output=True, text=True, env=env_for(**extra))


def calls(fake=FAKE):
    try:
        with open(os.path.join(fake, "calls.log")) as f:
            return [json.loads(l) for l in f if l.strip()]
    except OSError:
        return []


ok("the harness is executable", os.access(HARNESS, os.X_OK))
with open(HARNESS) as f:
    first = f.readline().strip()
is_("it runs under the system python", first, "#!/usr/bin/python3")

# ------------------------------------------------------------------ RP1 cases
print("RP1. cases")
S1 = os.path.join(ROOT, "state1")
p = harness(S1, "cases", "--dry-run")
is_("RP1 cases --dry-run exits 0", p.returncode, 0)
nonces = ("xr-2-r1", "xr-3-r2")
for n in nonces:
    ok("RP1 a judge input for {}".format(n), os.path.isfile(os.path.join(S1, "judge-known", n + ".json")), p.stderr)
ji = jl(os.path.join(S1, "judge-known", "xr-2-r1.json"))
is_("RP1 the judge input is {case, findings, interdiff}", sorted(ji), ["case", "findings", "interdiff"])
is_("RP1 it lists the P0-P2 findings only", [f["severity"] for f in ji["findings"]], ["P1"])
want_diff = LD.patch(repo, c1, c2).decode()
ok("RP1 the interdiff is the change from this round's tip to the next round's", ji["interdiff"] == want_diff, ji["interdiff"][:200])
ok("RP1 --dry-run writes no cases.json", not os.path.exists(os.path.join(S1, "cases.json")))
ok("RP1 the last round has no judge input (no fixing change follows)", not os.path.exists(os.path.join(S1, "judge-known", "xr-4-r3.json")))

# the judge answers; cases selects
wr(os.path.join(S1, "judge-known", "xr-2-r1.answer.json"), {"verdicts": [{"index": 0, "answer": "yes"}]})
wr(os.path.join(S1, "judge-known", "xr-3-r2.answer.json"), {"verdicts": [{"index": 0, "answer": "unclear"}]})
p = harness(S1, "cases")
is_("RP1 cases exits 0", p.returncode, 0)
cj = jl(os.path.join(S1, "cases.json"))
byid = dict((c["id"], c) for c in cj["cases"])
is_("RP1 only the round with a yes verdict is a case, in each class it fits",
    sorted(byid), ["xr-2-r1.pre"])
is_("RP1 it serves framing and omit_plans (its plan binds to the approved plan review)",
    byid["xr-2-r1.pre"]["switches"], ["framing", "omit_plans"])
is_("RP1 the known-real findings", [k["summary"] for k in byid["xr-2-r1.pre"]["known"]], ["f adds 2, not 1"])
is_("RP1 selected by switch", cj["selected"], {"framing": ["xr-2-r1.pre"], "omit_plans": ["xr-2-r1.pre"], "delta": [], "fit": []})

wr(os.path.join(S1, "judge-known", "xr-3-r2.answer.json"), {"verdicts": [{"index": 0, "answer": "yes"}]})
p = harness(S1, "cases")
cj = jl(os.path.join(S1, "cases.json"))
byid = dict((c["id"], c) for c in cj["cases"])
is_("RP1 a second round joins in every class it fits (pre-merge, delta, fresh thread)",
    sorted(byid), ["xr-2-r1.pre", "xr-3-r2.ctx", "xr-3-r2.inc", "xr-3-r2.pre"])
is_("RP1 the delta case forks the historical thread after the previous round's turn",
    byid["xr-3-r2.inc"]["fork"], {"thread": T, "last_turn": "tu1"})
is_("RP1 selected by switch, most recent first (fit holds the thread that would have moved)", cj["selected"],
    {"framing": ["xr-3-r2.pre", "xr-2-r1.pre"], "omit_plans": ["xr-3-r2.pre", "xr-2-r1.pre"],
     "delta": ["xr-3-r2.inc"], "fit": ["xr-3-r2.ctx"]})

# ------------------------------------------------------------------ RP2 run --dry-run
print("RP2. run --dry-run")
before = len(calls())
p = harness(S1, "run", "--dry-run")
is_("RP2 run --dry-run exits 0", p.returncode, 0)
is_("RP2 it starts no turn and calls nothing", len(calls()), before)
arms = jl(os.path.join(S1, "arms.json"))
is_("RP2 arms.json maps every case's labels to arms", sorted(arms), sorted(byid))
for cid, m in arms.items():
    ok("RP2 {} labels are random 8 hex characters".format(cid), all(re.match(r"\A[0-9a-f]{8}\Z", l) for l in m), list(m))


def arm_dir(cid, arm):
    return os.path.join(S1, "packets", cid, arm)


def packet(cid, arm):
    with open(os.path.join(arm_dir(cid, arm), "packet.txt"), "rb") as f:
        return f.read()


def names(cid):
    return sorted(v["arm"] for v in arms[cid].values())


is_("RP2 a pre-merge case runs A, A2, F and the omit_plans B", names("xr-2-r1.pre"), ["A", "A2", "B", "F"])
is_("RP2 a delta case runs A, A2, B", names("xr-3-r2.inc"), ["A", "A2", "B"])
reviewer = open(os.path.join(CONF, "reviewer.md"), "rb").read()
for cid, tip, base in (("xr-2-r1.pre", c1, c0), ("xr-3-r2.pre", c2, c0)):
    body = open(os.path.join(S1, "packets", cid, "body.md"), "rb").read()
    today = XP.today_packet(reviewer, body, [(RANGE, LD.patch(repo, base, tip))])
    ok("RP2 {} A is byte-identical to today's packet".format(cid), packet(cid, "A") == today)
    ok("RP2 {} A2 is byte-identical to today's packet".format(cid), packet(cid, "A2") == today)
    ok("RP2 {} F is framed".format(cid), b"Files in this change (" in packet(cid, "F"))
    ok("RP2 {} F shows the whole plan".format(cid), b"was shown whole in the approved plan review" not in packet(cid, "F"))
    b = packet(cid, "B")
    ok("RP2 {} B is framed and lists the plan its plan review covered".format(cid),
       b"Files in this change (" in b and b"was shown whole in the approved plan review xr-1-plan" in b)
ok("RP2 the delta case's B follows the previous round",
   b"This round follows xr-2-r1 on this thread" in packet("xr-3-r2.inc", "B"))
ok("RP2 its A is still today's full packet", b"Files in this change" not in packet("xr-3-r2.inc", "A"))
ok("RP2 the fresh-thread case's B is a framed full packet", b"Files in this change (" in packet("xr-3-r2.ctx", "B"))
ok("RP2 dry run starts no clone and leaves no thread record", not os.path.exists(os.path.join(S1, "threads.json")))

# ------------------------------------------------------------------ a real run, against the fake
print("RP2b. run against the fake daemon")
p = harness(S1, "run")
is_("RP2b run exits 0", p.returncode, 0)
arms = jl(os.path.join(S1, "arms.json"))
runs = {}
for cid, m in arms.items():
    for label, v in m.items():
        path = os.path.join(S1, "runs", cid, label + ".json")
        ok("RP2b run file {} {}".format(cid, v["arm"]), os.path.isfile(path), p.stderr[-400:])
        if os.path.isfile(path):
            runs[(cid, v["arm"])] = jl(path)
r = runs.get(("xr-2-r1.pre", "A"), {})
is_("RP2b a run file holds findings, tokens, compacted and slices", [k in r for k in ("findings", "tokens", "compacted", "slices")], [True] * 4)
is_("RP2b a fresh-thread run counts the turn's tokens", r.get("tokens"), 1000)
is_("RP2b a forked run counts only its own tokens, not the inherited history",
    runs[("xr-3-r2.inc", "A")]["tokens"], 1000)
cl = calls()
turns = [c for c in cl if c["cmd"] == "turn-start"]
is_("RP2b every arm started one turn", len(turns), len(arms["xr-2-r1.pre"]) + len(arms["xr-3-r2.pre"]) + len(arms["xr-3-r2.inc"]) + len(arms["xr-3-r2.ctx"]))
tips = set(t["head"] for t in turns)
ok("RP2b every turn ran in a scratch checkout at the tip of the round it reviews", tips <= {c1, c2} and tips == {c1, c2}, tips)
ok("RP2b the scratch checkouts are gone", not [d for d in os.listdir(os.path.join(S1)) if d.startswith("clones") and os.listdir(os.path.join(S1, d))])
ok("RP2b I-1 a turn's checkout holds only the branch at the round's tip and the destination at its base",
   all(set(l.split()[1] for l in t["refs"]) <= {t["head"], c0} and t["head"] in set(l.split()[1] for l in t["refs"])
       and sorted(l.split()[0] for l in t["refs"]) == ["refs/heads/feat", "refs/heads/main"] for t in turns), [t["refs"] for t in turns[:2]])
is_("RP2b I-1 and the packet's range resolves there", set(t["range_rc"] for t in turns), {0})
forks = [c for c in cl if c["cmd"] == "thread-fork"]
is_("RP2b a historical thread is forked only through the turn before the round", set(c["args"][c["args"].index("--last-turn") + 1] for c in forks if "--last-turn" in c["args"]), {"tu1"})
ok("RP2b the archived historical thread was unarchived before its first fork",
   [c["cmd"] for c in cl if c["cmd"] in ("thread-unarchive", "thread-fork") and not c.get("refused")][0] == "thread-unarchive")
st = jl(os.path.join(FAKE, "state.json"))
ok("RP2b every thread the run created, and the one it unarchived, ends archived",
   all(c["thread"] in st["archived"] for c in cl if c["cmd"] in ("thread-start", "thread-fork") and "thread" in c) and "thT" in st["archived"], st["archived"])
ok("RP2b at most 3 turns ran at once", 1 <= st["max"] <= 3, st["max"])
sch = set(t["schema"] for t in turns)
is_("RP2b framed arms use the framed schema, today's arms the old one", sch, {"findings.schema.json", "findings.framed.schema.json"})
prog = jl(os.path.join(S1, "progress.json"))
is_("RP2b the model and effort are recorded", (prog.get("model"), prog.get("effort")), ("fake-model", "high"))
ok("RP2b the token tally is recorded and no stop happened", prog["tokens"] > 0 and prog.get("stopped_at") is None, prog)
is_("RP2b m-7 every run file records its turn's model and effort", set((r["model"], r["effort"]) for r in runs.values()), {("fake-model", "high")})
ok("RP2b framing runs record coverage", runs[("xr-2-r1.pre", "F")].get("missing") == [], runs[("xr-2-r1.pre", "F")])

# ------------------------------------------------------------------ RP3 match
print("RP3. blind judge inputs")
p = harness(S1, "match")
is_("RP3 match exits 0", p.returncode, 0)
jm = jl(os.path.join(S1, "judge-match", "xr-2-r1.pre.json"))
is_("RP3 a match input is {case, known, runs}", sorted(jm), ["case", "known", "runs"])
is_("RP3 it holds every run's findings under its random label", sorted(jm["runs"]), sorted(arms["xr-2-r1.pre"]))
blob = ""
for d in ("judge-known", "judge-match"):
    for f in sorted(os.listdir(os.path.join(S1, d))):
        if not f.endswith(".answer.json"):
            blob += open(os.path.join(S1, d, f)).read()
leak = [w for w in ("A2", '"arm"', "omit_plans", "framing", "delta", "arms.json", "fit\"") if w in blob]
is_("RP3 no judge input names an arm or a switch", leak, [])
labels = dict((v["arm"], l) for l, v in arms["xr-2-r1.pre"].items())
ok("RP3 no judge input maps a label to an arm", not any(('"{}": "{}"'.format(l, a) in blob) for a, l in labels.items()))
is_("RP3 a label's run is just its findings", list(jm["runs"][labels["A"]][0]), ["severity", "file", "line", "summary", "failure_scenario"])

# canned answers for every case: all arms find the one known finding
for cid, m in arms.items():
    k = len(byid[cid]["known"])
    wr(os.path.join(S1, "judge-match", cid + ".answer.json"),
       {"matches": [{"known_index": i, "label": l, "finding_index": 0} for l in m for i in range(k)]})
p = harness(S1, "report")
is_("RP3 report exits 0", p.returncode, 0)
rep = jl(os.path.join(S1, "report.json"))
is_("RP3 every switch passes when every arm finds every known-real finding",
    dict((s, v["status"]) for s, v in rep["switches"].items()), {"framing": "pass", "omit_plans": "pass", "delta": "pass", "fit": "pass"})
ok("RP3 report.md is written", os.path.isfile(os.path.join(S1, "report.md")))
ok("RP3 and prints the table", "omit_plans" in p.stdout and "recall" in p.stdout.lower(), p.stdout[:300])

# ------------------------------------------------------------------ RP4 the pass bar
print("RP4. report computes recall and the pass bar")
S4 = os.path.join(ROOT, "state4")


def mk(state, cases, selected, arms_map, runs_map, matches, progress=None):
    """cases: {id: {known: [severities]}}; arms_map {id: {arm: label}}; runs_map {(id, arm): run dict};
    matches {(id, arm): [matched known indexes]}."""
    wr(os.path.join(state, "cases.json"), {"cases": [
        {"id": cid, "switches": [], "known": [{"index": i, "severity": s, "summary": "k%d" % i} for i, s in enumerate(c["known"])]}
        for cid, c in cases.items()], "selected": selected})
    wr(os.path.join(state, "arms.json"), dict((cid, dict((l, {"arm": a, "switch": None}) for a, l in m.items())) for cid, m in arms_map.items()))
    for (cid, arm), run in runs_map.items():
        wr(os.path.join(state, "runs", cid, arms_map[cid][arm] + ".json"), run)
    for cid, m in arms_map.items():
        got = [{"known_index": i, "label": arms_map[cid][a], "finding_index": 0 if i in matches.get((cid, a), []) else None}
               for a in m for i in range(len(cases[cid]["known"]))]
        if all((cid, a) in runs_map for a in m):
            wr(os.path.join(state, "judge-match", cid + ".answer.json"), {"matches": got})
    if progress:
        wr(os.path.join(state, "progress.json"), progress)


def run_of(tokens=100, compacted=False, verdict="changes", missing=None):
    return {"verdict": verdict, "findings": [{"severity": "P1"}], "tokens": tokens, "compacted": compacted,
            "slices": 1, "missing": missing, "error": None}


cases = {"c1.pre": {"known": ["P1", "P2"]}, "c2.pre": {"known": ["P0", "P2"]}}
amap = dict((c, {"A": "a" * 8, "A2": "b" * 8, "F": "c" * 8}) for c in cases)
amap["c1.pre"] = {"A": "a1a1a1a1", "A2": "a2a2a2a2", "F": "a3a3a3a3"}
amap["c2.pre"] = {"A": "b1b1b1b1", "A2": "b2b2b2b2", "F": "b3b3b3b3"}
rm = dict(((c, a), run_of(tokens=100 * (1 + i), compacted=(a == "A"))) for c in cases for i, a in enumerate(("A", "A2", "F")))
# passing: A finds {0}, {0,1}; A2 finds {0,1}, {1}; F finds {0}, {0,1} - recall F 3 >= min(A 3, A2 3)
good = {("c1.pre", "A"): [0], ("c2.pre", "A"): [0, 1], ("c1.pre", "A2"): [0, 1], ("c2.pre", "A2"): [1],
        ("c1.pre", "F"): [0], ("c2.pre", "F"): [0, 1]}
mk(S4, cases, {"framing": list(cases), "omit_plans": [], "delta": [], "fit": []}, amap, rm, good)
p = harness(S4, "report")
rep = jl(os.path.join(S4, "report.json"))["switches"]["framing"]
is_("RP4 recall per arm", (rep["recall"]["A"], rep["recall"]["A2"], rep["recall"]["F"]), (0.75, 0.75, 0.75))
is_("RP4 a pass: F recalls at least as often as the lower of A and A2, no P0/P1 miss, no coverage failure",
    (rep["status"], rep["misses"], rep["coverage"]), ("pass", 0, 0.0))
is_("RP4 tokens and compactions per arm", (rep["tokens"], rep["compactions"]),
    ({"A": 200, "A2": 400, "F": 600}, {"A": 2, "A2": 0, "F": 0}))
is_("RP4 n counts the cases that ran every arm", (rep["n"], rep["selected"]), (2, 2))

# failing: F finds fewer, and misses the P0 that both A and A2 found
bad = dict(good)
bad[("c2.pre", "A")] = [0, 1]
bad[("c2.pre", "A2")] = [0, 1]
bad[("c2.pre", "F")] = [1]
mk(S4, cases, {"framing": list(cases), "omit_plans": [], "delta": [], "fit": []}, amap, rm, bad)
harness(S4, "report")
rep = jl(os.path.join(S4, "report.json"))["switches"]["framing"]
is_("RP4 a fail on recall and on a missed P0 both A and A2 found", (rep["status"], rep["misses"]), ("fail", 1))

# coverage: an arm with framing whose approvals failed coverage over 10% of its runs
cov = dict(rm)
cov[("c1.pre", "F")] = run_of(verdict="approve", missing=["lib.py"])
mk(S4, cases, {"framing": list(cases), "omit_plans": [], "delta": [], "fit": []}, amap, cov, good)
harness(S4, "report")
rep = jl(os.path.join(S4, "report.json"))["switches"]["framing"]
is_("RP4 coverage failures over 10% fail the switch", (rep["status"], rep["coverage"]), ("fail", 0.5))

# a dependent switch holds while framing fails
dep_cases = {"c1.pre": {"known": ["P1"]}}
dmap = {"c1.pre": {"A": "d1d1d1d1", "A2": "d2d2d2d2", "F": "d3d3d3d3", "B": "d4d4d4d4"}}
drm = dict((("c1.pre", a), run_of()) for a in ("A", "A2", "F", "B"))
dm = dict((("c1.pre", a), [0]) for a in ("A", "A2", "B"))
dm[("c1.pre", "F")] = []
mk(S4, dep_cases, {"framing": ["c1.pre"], "omit_plans": ["c1.pre"], "delta": [], "fit": []}, dmap, drm, dm)
harness(S4, "report")
rep = jl(os.path.join(S4, "report.json"))["switches"]
is_("RP4 framing fails, and omit_plans, which passes on its own, is held back", (rep["framing"]["status"], rep["omit_plans"]["status"]), ("fail", "hold"))

# ------------------------------------------------------------------ RP5 an interrupted run archives its threads
print("RP5. an interrupted run archives every thread it recorded")
S5 = os.path.join(ROOT, "state5")
FAKE5 = os.path.join(ROOT, "fake5")
shutil_copy = lambda a, b: wr(b, open(a).read())
harness(S5, "cases")
for n in nonces:
    shutil_copy(os.path.join(S1, "judge-known", n + ".answer.json"), os.path.join(S5, "judge-known", n + ".answer.json"))
harness(S5, "cases")
env5 = env_for(FAKE_STATE=FAKE5, FAKE_HANG="1")
proc = subprocess.Popen([HARNESS, "run", "--state", S5], env=env5, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
deadline = time.time() + 30
seen = []
while time.time() < deadline:
    try:
        seen = [t for t in jl(os.path.join(S5, "threads.json"))["threads"]]
    except (OSError, ValueError, KeyError):
        seen = []
    if len(seen) >= 3:
        break
    time.sleep(0.1)
ok("RP5 the run recorded threads before it was interrupted", len(seen) >= 3, seen)
proc.send_signal(signal.SIGTERM)
try:
    proc.wait(timeout=30)
except subprocess.TimeoutExpired:
    proc.kill()
    ok("RP5 the run ends on SIGTERM", False)
recorded = [t["thread"] for t in jl(os.path.join(S5, "threads.json"))["threads"]]
st5 = jl(os.path.join(FAKE5, "state.json"))
ok("RP5 every recorded thread is archived", recorded and all(t in st5["archived"] for t in recorded), (recorded, st5["archived"]))
ok("RP5 the unarchived historical thread is archived again", "thT" in st5["archived"], st5["archived"])
ok("RP5 no scratch checkout is left", not [x for x in os.listdir(S5) if x.startswith("clones") and os.listdir(os.path.join(S5, x))])
ok("RP5 an interrupted run is not a success", proc.returncode != 0, proc.returncode)

# ------------------------------------------------------------------ RP6 a truncated run is incomplete
print("RP6. a run cut off by the token stop reports the switch incomplete")
S6 = os.path.join(ROOT, "state6")
FAKE6 = os.path.join(ROOT, "fake6")
harness(S6, "cases")
for n in nonces:
    shutil_copy(os.path.join(S1, "judge-known", n + ".answer.json"), os.path.join(S6, "judge-known", n + ".answer.json"))
harness(S6, "cases")
p = subprocess.run([HARNESS, "run", "--state", S6, "--max-tokens", "3500"], env=env_for(FAKE_STATE=FAKE6), capture_output=True, text=True)
prog = jl(os.path.join(S6, "progress.json"))
ok("RP6 the run stopped at the token cap and recorded where", prog.get("stopped_at") and prog["tokens"] >= 3500, prog)
arms6 = jl(os.path.join(S6, "arms.json"))
done = dict((cid, [l for l in m if os.path.isfile(os.path.join(S6, "runs", cid, l + ".json"))]) for cid, m in arms6.items())
ok("RP6 some arms ran and not all", 0 < sum(len(v) for v in done.values()) < sum(len(m) for m in arms6.values()), done)
# the cases that finished meet the bar: canned answers where every arm ran
for cid, m in arms6.items():
    if len(done[cid]) == len(m):
        wr(os.path.join(S6, "judge-match", cid + ".answer.json"),
           {"matches": [{"known_index": 0, "label": l, "finding_index": 0} for l in m]})
harness(S6, "report")
rep = jl(os.path.join(S6, "report.json"))
st = dict((s, v["status"]) for s, v in rep["switches"].items())
ok("RP6 no switch is passed", "pass" not in st.values(), st)
is_("RP6 the switches that did not finish are incomplete", set(st.values()), {"incomplete"})
ok("RP6 report.md says where the run stopped", "stopped" in open(os.path.join(S6, "report.md")).read().lower())

# a rerun finishes the work, without redoing what is done
p = subprocess.run([HARNESS, "run", "--state", S6], env=env_for(FAKE_STATE=FAKE6), capture_output=True, text=True)
is_("RP6 a rerun exits 0", p.returncode, 0)
arms6b = jl(os.path.join(S6, "arms.json"))
is_("RP6 and keeps the labels", arms6b, arms6)
ok("RP6 and every arm has run", all(os.path.isfile(os.path.join(S6, "runs", cid, l + ".json")) for cid, m in arms6b.items() for l in m))
turn_count = len([c for c in calls(FAKE6) if c["cmd"] == "turn-start"])
is_("RP6 each arm ran exactly once across both runs", turn_count, sum(len(m) for m in arms6b.values()))


# ------------------------------------------------------------------ the fix round
def fresh(name, **extra):
    state = os.path.join(ROOT, name)
    harness(state, "cases", **extra)
    for n in nonces:
        shutil_copy(os.path.join(S1, "judge-known", n + ".answer.json"), os.path.join(state, "judge-known", n + ".answer.json"))
    harness(state, "cases", **extra)
    return state, os.path.join(ROOT, "fake-" + name)


def runfiles(state):
    out = []
    for cid, m in jl(os.path.join(state, "arms.json")).items():
        for label, v in m.items():
            path = os.path.join(state, "runs", cid, label + ".json")
            if os.path.isfile(path):
                out.append((cid, v["arm"], jl(path)))
    return out


print("RP8. m-6 and m-2: a schema-failed answer is an error run, shown by report and retried only on request")
S8, FAKE8 = fresh("s8")
p = subprocess.run([HARNESS, "run", "--state", S8], env=env_for(FAKE_STATE=FAKE8, FAKE_RC4="1"), capture_output=True, text=True)
rf = runfiles(S8)
ok("RP8 every run is an error that says schema-failed", len(rf) == 14 and all("schema-failed" in (r["error"] or "") for _c, _a, r in rf), [r["error"] for _c, _a, r in rf][:2])
n_turns = len([c for c in calls(FAKE8) if c["cmd"] == "turn-start"])
subprocess.run([HARNESS, "run", "--state", S8], env=env_for(FAKE_STATE=FAKE8), capture_output=True, text=True)
is_("RP8 a plain rerun does not retry error runs", len([c for c in calls(FAKE8) if c["cmd"] == "turn-start"]), n_turns)
harness(S8, "report")
rep = jl(os.path.join(S8, "report.json"))
is_("RP8 report lists every error run with its reason", len(rep["errors"]), 14)
ok("RP8 and report.md shows them", "schema-failed" in open(os.path.join(S8, "report.md")).read())
ok("RP8 no switch passes on error runs", "pass" not in [v["status"] for v in rep["switches"].values()])
subprocess.run([HARNESS, "run", "--state", S8, "--retry-errors"], env=env_for(FAKE_STATE=FAKE8), capture_output=True, text=True)
rf = runfiles(S8)
ok("RP8 --retry-errors runs them again and they now succeed", len(rf) == 14 and not any(r["error"] for _c, _a, r in rf), [r["error"] for _c, _a, r in rf][:2])
is_("RP8 N5 a retried run reports its final attempt's tokens, and spent counts every attempt",
    (sorted(set(r["tokens"] for _c, _a, r in rf)), sorted(set(r["spent"] for _c, _a, r in rf))), ([1000], [2000]))
is_("RP8 N5 and the stop tally counts every attempt", jl(os.path.join(S8, "progress.json"))["tokens"], 14 * 2000)

print("RP9. I-2: a turn that outlives the budget keeps its slot; its tokens are charged")
S9, FAKE9 = fresh("s9")
subprocess.run([HARNESS, "run", "--state", S9, "--budget", "0.25"], env=env_for(FAKE_STATE=FAKE9, FAKE_RC3="5"), capture_output=True, text=True)
rf = runfiles(S9)
ok("RP9 every run is an error that names the budget", len(rf) == 14 and all("budget" in (r["error"] or "") for _c, _a, r in rf), [r["error"] for _c, _a, r in rf][:2])
ok("RP9 and still carries the tokens the late turn used", all(r["tokens"] > 0 for _c, _a, r in rf), [r["tokens"] for _c, _a, r in rf])
ok("RP9 at most 3 turns were ever running at once", jl(os.path.join(FAKE9, "state.json"))["max"] <= 3, jl(os.path.join(FAKE9, "state.json"))["max"])
is_("RP9 and the stop counts their tokens", jl(os.path.join(S9, "progress.json"))["tokens"], 14 * 1000)

print("RP5b. I-2: an interrupted job is recorded with its error; m-3: a thread being created is recorded")
SA, FAKEA = fresh("sa")
proc = subprocess.Popen([HARNESS, "run", "--state", SA], env=env_for(FAKE_STATE=FAKEA, FAKE_SLOW_START="1.5"), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
t0 = time.time()
while time.time() - t0 < 30 and not os.path.exists(os.path.join(FAKEA, "starting")):
    time.sleep(0.05)
time.sleep(0.3)
proc.send_signal(signal.SIGTERM)
proc.wait(timeout=60)
made = [c["thread"] for c in calls(FAKEA) if c["cmd"] == "thread-start"]
rec = [t["thread"] for t in jl(os.path.join(SA, "threads.json"))["threads"]]
stA = jl(os.path.join(FAKEA, "state.json"))
ok("RP5b a thread whose creation was under way at the signal was allowed to finish, is recorded and archived",
   made and all(t in rec and t in stA["archived"] for t in made), (made, rec, stA["archived"]))
rf = runfiles(SA)
ok("RP5b the interrupted jobs wrote run files that say so", rf and all(r.get("interrupted") and r["error"] for _c, _a, r in rf), rf[:1])
subprocess.run([HARNESS, "run", "--state", SA], env=env_for(FAKE_STATE=FAKEA), capture_output=True, text=True)
rf = runfiles(SA)
ok("RP5b a rerun redoes the interrupted jobs without --retry-errors", len(rf) == 14 and not any(r["error"] for _c, _a, r in rf), [r["error"] for _c, _a, r in rf][:2])

print("RP10. m-1: B must exercise its switch")
Hm = load(HARNESS, "replay_m")
dec = lambda **kw: dict({"action": "send", "kind": "full", "reason": "", "packets": [], "targets": [{"plans_from": []}]}, **kw)
ok("RP10 a delta B that built a full packet is rejected", "not a delta" in (Hm.exercised({"class": "inc"}, "delta", dec()) or ""))
is_("RP10 a delta B that built a delta is accepted", Hm.exercised({"class": "inc"}, "delta", dec(kind="delta")), None)
ok("RP10 a big B that was not sliced is rejected", "not sliced" in (Hm.exercised({"class": "big"}, "fit", dec()) or ""))
is_("RP10 a sliced big B is accepted", Hm.exercised({"class": "big"}, "fit", dec(action="slices", kind="slices")), None)
big = os.path.join(ROOT, "bigpacket")
wr(big, "x" * 400000)
ok("RP10 a ctx B whose packet fits the historical thread is rejected",
   "would have fit" in (Hm.exercised({"class": "ctx", "ctx_before": 1000, "window": 200000}, "fit", dec(packets=[{"file": big}])) or ""))
is_("RP10 a ctx B whose packet does not fit it is accepted",
    Hm.exercised({"class": "ctx", "ctx_before": 175000, "window": 200000}, "fit", dec(packets=[{"file": big}])), None)
ok("RP10 an omit_plans B that listed no plan is rejected", "no plan" in (Hm.exercised({"class": "pre"}, "omit_plans", dec()) or ""))
is_("RP10 one that listed a plan is accepted", Hm.exercised({"class": "pre"}, "omit_plans", dec(targets=[{"plans_from": [{"path": "p"}]}])), None)
ok("RP10 a refused B is rejected", "refused" in (Hm.exercised({"class": "pre"}, "omit_plans", dec(action="refuse", reason="no")) or ""))

print("RP11. m-4: rounds chain by thread, branch and destination")
XDG2 = os.path.join(ROOT, "xdg2")
other = dict(target(c2), branch="other")
E = [receipt("xr-a", 1, "pre-merge", T, "ta", target(c1), "changes"), receipt("xr-b", 2, "pre-merge", T, "tb", other, "changes"),
     receipt("xr-c", 3, "pre-merge", T, "tc", target(c2), "changes")]
ld2 = os.path.join(XDG2, "xreview", "ledgers", LD.ledger_key(common))
wr(os.path.join(ld2, "reviews.jsonl"), "".join(json.dumps(e) + "\n" for e in E))
wr(os.path.join(ld2, "repo"), common + "\n")
os.environ["XDG_STATE_HOME"] = XDG2
got = dict((r["nonce"], (r["k"], r["prev"] and r["prev"]["nonce"], r["next"] and r["next"]["nonce"])) for r in Hm.load_rounds())
os.environ["XDG_STATE_HOME"] = XDG
is_("RP11 one thread, two branches: each branch is its own chain", got,
    {"xr-a": (1, None, "xr-c"), "xr-b": (1, None, None), "xr-c": (2, "xr-a", None)})

print("RP12. m-7: report flags a case whose arms ran at different models")
S12 = os.path.join(ROOT, "state12")
rm12 = dict(((c, a), run_of()) for c in cases for a in ("A", "A2", "F"))
for k in rm12:
    rm12[k] = dict(rm12[k], model="m-1", effort="high")
rm12[("c2.pre", "F")] = dict(rm12[("c2.pre", "F")], model="m-2")
mk(S12, cases, {"framing": list(cases), "omit_plans": [], "delta": [], "fit": []}, amap, rm12, good)
harness(S12, "report")
is_("RP12 the mixed case is flagged", jl(os.path.join(S12, "report.json"))["mixed_models"], ["c2.pre"])
ok("RP12 and report.md says so", "different models" in open(os.path.join(S12, "report.md")).read())

print("RP13. N1: a repeated total after a compaction is not new usage")
homeC = os.path.join(ROOT, "codexC")


def tc(total, last):
    return {"type": "event_msg", "payload": {"type": "token_count", "info": {
        "total_token_usage": {"total_tokens": total}, "last_token_usage": {"total_tokens": last}, "model_context_window": 258400}}}


recs = [tc(700, 700),
        {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "tuC"}},
        {"type": "turn_context", "payload": {"turn_id": "tuC", "model": "m-1", "effort": "high"}},
        tc(1700, 1000), {"type": "compacted", "payload": {"message": ""}}, tc(1700, 90000), tc(3200, 1500),
        {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "tuC", "last_agent_message": "{}"}},
        {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "tuD"}}, tc(3200, 90000), tc(4000, 800)]
wr(os.path.join(homeC, "sessions", "2026", "10", "20", "rollout-2026-10-20T00-00-00-thC.jsonl"), "".join(json.dumps(r) + "\n" for r in recs))
os.environ["CODEX_HOME"] = homeC
is_("RP13 the compacted turn is charged its two real calls, not the compacted context", Hm.turn_usage("thC", "tuC")["tokens"], 2500)
is_("RP13 a later turn's repeated first total is not charged either", Hm.turn_usage("thC", "tuD")["tokens"], 800)

print("RP14. N2: a range written origin/<dest>...<branch> resolves in the checkout")
XDG3 = os.path.join(ROOT, "xdg3")
ld3 = os.path.join(XDG3, "xreview", "ledgers", LD.ledger_key(common))
R3 = copy_R = json.loads(json.dumps(R))
for e in R3:
    e["targets"][0].update(dest_ref="origin/main", range="origin/main...feat")
wr(os.path.join(ld3, "reviews.jsonl"), "".join(json.dumps(e) + "\n" for e in R3))
wr(os.path.join(ld3, "repo"), common + "\n")
S14, FAKE14 = fresh("s14", XDG_STATE_HOME=XDG3)
subprocess.run([HARNESS, "run", "--state", S14], env=env_for(FAKE_STATE=FAKE14, XDG_STATE_HOME=XDG3, FAKE_RANGE="origin/main...feat"), capture_output=True, text=True)
t14 = [c for c in calls(FAKE14) if c["cmd"] == "turn-start"]
is_("RP14 every arm ran", len(t14), 14)
is_("RP14 origin/main...feat resolves in every turn's checkout", set(t["range_rc"] for t in t14), {0})
ok("RP14 and the refs are the branch, the destination and origin/<dest> at the base",
   all(sorted(l.split()[0] for l in t["refs"]) == ["refs/heads/feat", "refs/heads/main", "refs/remotes/origin/main"] for t in t14), t14[0]["refs"])
ok("RP14 the body quotes that range", "origin/main...feat" in open(os.path.join(S14, "packets", "xr-2-r1.pre", "body.md")).read())

print("RP15. N4: a turn that finishes after the deadline is over budget")
S15, FAKE15 = fresh("s15")
subprocess.run([HARNESS, "run", "--state", S15, "--budget", "0.25"], env=env_for(FAKE_STATE=FAKE15, FAKE_WAIT="0.6"), capture_output=True, text=True)
rf = runfiles(S15)
ok("RP15 even a turn that finished on its first wait is an error run", len(rf) == 14 and all("budget" in (r["error"] or "") for _c, _a, r in rf), [r["error"] for _c, _a, r in rf][:2])

print("RP16. N5: a job that finished before it noticed the stop is complete")
import argparse
homeU = os.path.join(ROOT, "codexU")
rollout(homeU, "thU", [("tuU", None, APPROVE, False)])
os.environ["CODEX_HOME"] = homeU
unit = os.path.join(ROOT, "unit")
wr(os.path.join(unit, "packet.txt"), "x")
job = {"case": "c.pre", "arm": "A", "label": "u1u1u1u1", "framing": False, "repo": common, "target": target(c1), "tip": c1, "fork": None,
       "error": None, "decision": {"kind": "full", "action": "send", "packets": [{"file": os.path.join(unit, "packet.txt"), "shown": []}]}}
na = argparse.Namespace(state=unit, budget=10)
Hm.TH = Hm.Threads(unit)


def scripted(wait_rc, stop):
    def fake(*args):
        if args[0] == "thread-start":
            return 0, "thU\n", ""
        if args[0] == "turn-start":
            return 0, "tuU\n", ""
        if args[0] == "turn-wait":
            if stop:
                Hm.STOP.set()
            return wait_rc, (json.dumps(APPROVE) if wait_rc == 0 else ""), ""
        return 0, "", ""
    return fake


Hm.rpc = scripted(0, True)
res = Hm.run_job(na, job)
Hm.STOP.clear()
ok("RP16 a job whose last answer arrived as the stop was set is complete", res["error"] is None and not res.get("interrupted") and res["verdict"] == "approve", res)
job["label"] = "u2u2u2u2"
Hm.rpc = scripted(3, True)
res = Hm.run_job(na, job)
Hm.STOP.clear()
ok("RP16 a job cut off by the stop is interrupted", res["interrupted"] is True and "interrupted" in res["error"], res)
job["label"] = "u3u3u3u3"
Hm.rpc = scripted(1, False)
res1 = Hm.run_job(na, job)
Hm.rpc = scripted(0, False)
res2 = Hm.run_job(na, job)
is_("RP16 a retry reports its own tokens and spends both attempts'", (res1["tokens"], res2["tokens"], res2["spent"]), (1000, 1000, 2000))

print("RP17. N6: a crashed run is not recorded as finished")
Hc = None
os.environ.update(XREVIEW_REPLAY_RPC=FAKE_BIN, FAKE_STATE=os.path.join(ROOT, "fake-sc"), XDG_STATE_HOME=XDG, CODEX_HOME=CODEX)
Hc = load(HARNESS, "replay_c")
SC, _ = fresh("sc")
Hc.run_job = lambda a, job: (_ for _ in ()).throw(RuntimeError("boom"))
old = dict((sg, signal.getsignal(sg)) for sg in (signal.SIGINT, signal.SIGTERM))
rcc = Hc.cmd_run(argparse.Namespace(state=SC, dry_run=False, max_tokens=60000000, budget=10, retry_errors=False))
for sg, h in old.items():
    signal.signal(sg, h)
pc = jl(os.path.join(SC, "progress.json"))
is_("RP17 the run reports failure", rcc, 1)
ok("RP17 progress.json says it did not finish, and why", pc["finished"] is False and "boom" in (pc["crashed"] or ""), pc)

# ------------------------------------------------------------------ RP7 rollouts the daemon compressed
print("RP7. a compressed, archived rollout reads like a plain one")
import shutil
if shutil.which("zstd"):
    H = load(HARNESS, "replay")
    home7 = os.path.join(ROOT, "codex7")
    rollout(home7, "thZ", [("tuZ", 1234, F1, True)], sub="archived_sessions", stamp="2026-10-01T00-00-00")
    plain = os.path.join(home7, "archived_sessions", "rollout-2026-10-01T00-00-00-thZ.jsonl")
    subprocess.run(["zstd", "-q", "--rm", plain], check=True)
    os.environ["CODEX_HOME"] = home7
    got = H.turns_of("thZ")
    is_("RP7 the turn, its final answer, its context and its compaction",
        (list(got), json.loads(got["tuZ"]["final"])["verdict"], got["tuZ"]["ctx_before"], got["tuZ"]["compacted"]),
        (["tuZ"], "changes", 1234, True))
    is_("RP7 m-8 a turn's tokens are the token_counts inside it, not the history before it",
        H.turn_usage("thZ", "tuZ"), {"tokens": 1000, "model": "m-1", "effort": "high"})

PY
)"
rc=$?
printf '%s\n' "$out"
pass=$(printf '%s\n' "$out" | grep -c '^  PASS:')
fail=$(printf '%s\n' "$out" | grep -c '^  FAIL:')
if [ "$rc" -ne 0 ]; then fail=$((fail + 1)); echo "  FAIL: the python checks died (exit $rc)"; fi
printf '\npassed: %d/%d  failed: %d\n' "$pass" "$((pass + fail))" "$fail"
(( fail == 0 ))
