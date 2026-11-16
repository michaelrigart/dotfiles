// What the spaces pane draws from patches/rows.js and patches/phases.js, run headless under jsc by
// tests/herdr-app.test.sh (./stubs.js stands in for the app's modules). Assertions are on data and
// on the structure the builders recorded: which text sits in which colour, which marks exist.
import { Phases, tones, marks } from "./phases.js";
import { Rows } from "./rows.js";

const check = (what, ok) => print(`  ${ok ? "PASS" : "FAIL"}: ${what}`);

const store = {};
globalThis.localStorage = { getItem: (k) => store[k] ?? null, setItem: (k, v) => { store[k] = String(v); } };

// A theme whose every colour is its own name, so an assertion reads "ansi1" or "muted".
const t = new Proxy({}, { get: (_, k) => String(k) });

const texts = (n) => (typeof n === "string" ? [n] : n.kids.flatMap(texts));
const has = (n, s) => texts(n).includes(s);
const findNode = (n, pred) => {
  if (typeof n === "string") return null;
  if (pred(n)) return n;
  for (const k of n.kids) { const f = findNode(k, pred); if (f) return f; }
  return null;
};
const holding = (n, s) => findNode(n, (x) => x.kids.includes(s)); // the node whose own child is the text s
const colorOf = (n) => n?.calls.filter(([m]) => m === "text_color").pop()?.[1][0];
const saved = () => JSON.parse(store["repos.folded"] ?? "[]");
const tip = (n) => n.calls.filter(([m]) => m === "tooltip").pop()?.[1][0];

const phases = Object.create(Phases.prototype);
phases.by = {};
phases.defaults = {};
let rows = new Rows(phases);
const fresh = () => { for (const k of Object.keys(store)) delete store[k]; phases.by = {}; phases.defaults = {}; rows = new Rows(phases); };

// --- asBranch: a worktree row's name is the automatic one ------------------------------------
{
  const g = { name: "chezmoi", branch: "fix/merge-full-sha" };
  const w = (name) => ({ id: "s", name });
  check("asBranch: the name wt gave (repo-branch slug) is automatic", rows.asBranch(w("chezmoi-fix-merge-full-sha"), g, "├─") === "fix/merge-full-sha");
  check("asBranch: ...compared without case", rows.asBranch(w("Chezmoi-FIX-merge-full-SHA"), g, "└─") === "fix/merge-full-sha");
  check("asBranch: a name that is the branch itself is automatic", rows.asBranch(w("fix/merge-full-sha"), g, "├─") === "fix/merge-full-sha");
  check("asBranch: a renamed space is not", rows.asBranch(w("my thing"), g, "├─") === null);
  check("asBranch: only a nested row", rows.asBranch(w("chezmoi-fix-merge-full-sha"), g, null) === null);
  check("asBranch: not a detached HEAD", rows.asBranch(w("chezmoi-(detached)"), { name: "chezmoi", branch: "(detached)" }, "├─") === null);
  check("asBranch: not a row without git", rows.asBranch(w("x"), null, "├─") === null);
}

// --- label: the branch with its type dimmed; a merged one muted -------------------------------
{
  fresh();
  const g = { name: "chezmoi", branch: "fix/merge-full-sha" };
  const auto = { id: "s1", name: "chezmoi-fix-merge-full-sha" };
  const l = rows.label(auto, g, "├─", t);
  check("label: type and rest are separate texts, the type dimmed", typeof l !== "string"
    && colorOf(holding(l, "fix/")) === "dim" && has(l, "merge-full-sha") && !has(l, "fix/merge-full-sha"));
  check("label: the rest keeps the row's colour", colorOf(holding(l, "merge-full-sha")) === undefined);
  check("label: a branch without a type is its own text", rows.label({ id: "s2", name: "chezmoi-wip" }, { name: "chezmoi", branch: "wip" }, "├─", t) === "wip");
  check("label: a renamed space shows its name", rows.label({ id: "s3", name: "my thing" }, g, "├─", t) === "my thing");
  check("label: a space that is not nested shows its name", rows.label(auto, g, null, t) === auto.name);
  phases.by.s1 = { phase: "merged" };
  const m = rows.label(auto, g, "├─", t);
  check("label: merged: the rest is muted, the type stays dimmer", colorOf(holding(m, "merge-full-sha")) === "muted" && colorOf(holding(m, "fix/")) === "dim");
  phases.by.s3 = { phase: "merged" };
  const r = rows.label({ id: "s3", name: "my thing" }, g, "├─", t);
  check("label: merged: a renamed name is muted too", typeof r !== "string" && has(r, "my thing") && colorOf(r) === "muted");
  phases.by.s4 = { phase: "review" };
  check("label: other phases are not muted", rows.label({ id: "s4", name: "my thing" }, g, "├─", t) === "my thing");
}

// --- fold, mergedLast: what is drawn, what is recorded ---------------------------------------
const R1 = "repo-1", R2 = "repo-2";
const row = (id, repo, tree, w = {}) => ({ w: { id, name: id, active: false, status: null, ...w }, g: { repo }, tree });
const ids = (list) => list.map((r) => r.w.id).join();
{
  fresh();
  const stored = [row("main1", R1, null), row("a", R1, "├─"), row("b", R1, "├─"), row("c", R1, "└─"),
                  row("main2", R2, null), row("d", R2, "└─"), row("lone", "other", null)];
  const before = ids(stored);
  check("fold: nothing folded, every row is drawn", ids(rows.fold(stored, false)) === before);
  check("fold: the count and the owning row are recorded per repository", rows.kids[R1] === 3 && rows.kids[R2] === 1
    && rows.owner[R1] === "main1" && rows.owner[R2] === "main2" && rows.kids.other === undefined);
  rows.hidden.add(R1);
  check("fold: a folded repository's nested rows are left out, the rest stay", ids(rows.fold(stored, false)) === "main1,main2,d,lone");
  check("fold: ...and are still counted", rows.kids[R1] === 3 && rows.under[R1].length === 3);
  check("fold: the narrow rail ignores a fold", ids(rows.fold(stored, true)) === before);
  check("fold: the stored rows are not reordered or emptied", ids(stored) === before);
}
{
  fresh();
  phases.by = { a: { phase: "merged" }, b: { phase: "active" }, c: { phase: "merged" }, d: { phase: "review" }, e: { phase: "merged" }, f: { phase: "active" } };
  const stored = [row("main1", R1, null), row("a", R1, "├─"), row("b", R1, "├─"), row("c", R1, "├─"), row("d", R1, "└─"),
                  row("main2", R2, null), row("e", R2, "├─"), row("f", R2, "└─")];
  const before = ids(stored);
  check("mergedLast: merged last in each repository, each group in its stored order", ids(rows.mergedLast(stored)) === "main1,b,d,a,c,main2,f,e");
  check("mergedLast: the stored order is untouched", ids(stored) === before);
  check("fold: drawn order puts merged last; owners and counts come from the stored order", ids(rows.fold(stored, false)) === "main1,b,d,a,c,main2,f,e"
    && rows.owner[R1] === "main1" && rows.kids[R1] === 4);
  check("fold: the rail keeps the stored order", ids(rows.fold(stored, true)) === before);
  phases.by = {};
  check("mergedLast: rows with no phase yet keep their place", ids(rows.mergedLast(stored)) === before);
}

// --- waiting, urgent, toggle, end ------------------------------------------------------------
{
  fresh();
  check("waiting: a blocked agent is waiting", rows.waiting({ status: "blocked" }) === true);
  check("waiting: working, idle, done and none are not", ["working", "idle", "done", null].every((s) => rows.waiting({ status: s }) === false));
}
const glyphs = (flags) => flags.map((f) => f[0]).join(" ");
const folded = (kids, by = {}) => {
  fresh();
  phases.by = by;
  const stored = [row("main", R1, null), ...kids.map(([id, w]) => row(id, R1, "├─", w))];
  rows.fold(stored, false);
  return stored;
};
{
  folded([["a", {}], ["b", {}]]);
  check("urgent: nothing to say is no mark", rows.urgent(R1, t).length === 0);
  folded([["a", {}], ["b", { active: true }]]);
  check("urgent: the space you are in, hidden", glyphs(rows.urgent(R1, t)) === "◆");
  folded([["a", {}], ["b", { active: true }]], { a: { phase: "review" } });
  const rv = rows.urgent(R1, t);
  check("urgent: a review waiting outranks the hidden current space, in the review colour", glyphs(rv) === "review" && rv[0][1] === tones(t).review);
  folded([["a", {}], ["b", { active: true }]], { a: { phase: "review", ci: "fail" } });
  const cf = rows.urgent(R1, t);
  check("urgent: CI failed outranks a review, in the failed colour", glyphs(cf) === marks(t).fail[0] && cf[0][1] === marks(t).fail[1]);
  folded([["a", { status: "blocked" }], ["b", {}]], { b: { phase: "review" } });
  const aw = rows.urgent(R1, t);
  check("urgent: an agent waiting outranks a review", aw.length === 1 && aw[0][0] === "!" && aw[0][1] === "blocked");
  folded([["a", { status: "blocked" }], ["b", {}]], { b: { phase: "review", ci: "fail" } });
  const both = rows.urgent(R1, t);
  check("urgent: an agent waiting and a failed CI both show, as different glyphs", both.length === 2
    && both[0][0] !== both[1][0] && both.some((f) => f[0] === "!") && both.some((f) => f[0] === marks(t).fail[0]));
  check("urgent: a failed CI is a different red glyph than an agent waiting", marks(t).fail[0] !== "!");
  folded([["a", { status: "working" }], ["b", { status: "idle" }]], { a: { phase: "active" } });
  check("urgent: working and idle agents say nothing", rows.urgent(R1, t).length === 0);
  folded([["a", {}]], {});
  check("urgent: a hidden worktree with no phase data says nothing", rows.urgent(R1, t).length === 0);
}
{
  // toggle: the chevron, the count while folded, the marks beside it.
  folded([["a", { status: "blocked" }], ["b", {}], ["c", {}]]);
  const open = rows.toggle("main", t);
  check("toggle: unfolded shows no count and no marks", open.length === 1 && !texts(open[0]).includes("3") && texts(open[0]).length === 0);
  check("toggle: only the owning row has one", rows.toggle("a", t).length === 0 && rows.toggle("nobody", t).length === 0);
  open[0].handlers.on_click({}, { stop_propagation() {}, notify() {} });
  check("toggle: a click folds the repository and remembers it", rows.hidden.has(R1) && saved().includes(R1));
  const shut = rows.toggle("main", t);
  check("toggle: folded shows the hidden count and an agent waiting", has(shut[0], "3") && has(shut[0], "!") && colorOf(holding(shut[0], "!")) === "blocked");
  check("toggle: the tooltip names the reason", /\S/.test(tip(shut[0]) ?? "") && tip(shut[0]) !== tip(open[0]));
  shut[0].handlers.on_click({}, { stop_propagation() {}, notify() {} });
  check("toggle: a second click unfolds and forgets it", !rows.hidden.has(R1) && !saved().includes(R1));
  store["repos.folded"] = JSON.stringify([R1]);
  check("toggle: a fold survives a reload", new Rows(phases).hidden.has(R1));
  store["repos.folded"] = "not json";
  check("toggle: unreadable saved folds mean nothing is folded", new Rows(phases).hidden.size === 0);
}
{
  folded([["a", {}], ["b", {}]]);
  rows.hidden.add(R1);
  const quiet = rows.toggle("main", t);
  check("toggle: folded with nothing to say shows the count only", texts(quiet[0]).join() === "2");
}
{
  fresh();
  const mark = (w) => rows.end(w, t).find((n) => n.calls?.some(([m, a]) => m === "id" && String(a[0]).startsWith("waiting-")));
  const waiting = mark({ id: "s", status: "blocked" });
  check("end: a waiting agent gets a mark in the needs-you colour", waiting && has(waiting, "!") && colorOf(waiting) === "blocked");
  check("end: ...and a working, idle or empty space gets none", ["working", "idle", "done", null].every((s) => mark({ id: "s", status: s }) === undefined));
  check("end: a plain space ends on nothing", rows.end({ id: "s", status: null }, t).length === 0);
}

// --- badge: what each phase says ---------------------------------------------------------------
{
  fresh();
  const badge = (r) => { phases.by.s = r; return phases.badge("s", t); };
  check("badge: a space with local work and no MR has none", badge({ phase: "active", ref: "", ci: "" }).length === 0);
  check("badge: a space nothing is known about has none", (delete phases.by.s, phases.badge("s", t).length === 0));
  const run = badge({ phase: "review", ref: "#4", ci: "run" })[0];
  check("badge: CI running is its own yellow glyph, not a dot", colorOf(holding(run, marks(t).run[0])) === marks(t).run[1]
    && marks(t).run[0] !== "●" && marks(t).run[1] === "ansi3");
  const ok = badge({ phase: "review", ref: "#4", ci: "ok" })[0];
  const fail = badge({ phase: "review", ref: "#4", ci: "fail" })[0];
  check("badge: CI passed and failed keep their glyphs and colours", has(ok, "✓") && colorOf(holding(ok, "✓")) === "ansi2"
    && has(fail, "✕") && colorOf(holding(fail, "✕")) === "ansi1");
  check("badge: the phase and its reference read as one text, in the phase's colour", colorOf(holding(run, "review #4")) === tones(t).review);
  check("badge: waiting on others, in progress and needs you are three different colours",
    new Set([tones(t).review, marks(t).run[1], marks(t).fail[1]]).size === 3);
  const all = ["draft", "review", "merged", "not wt"].map((p) => badge({ phase: p, ref: p === "not wt" ? "" : "#1", ci: "" })[0]);
  check("badge: no phase is a dot", all.every((b) => !texts(b).some((s) => s.includes("●"))));
  check("badge: draft and merged are quiet colours", tones(t).draft === "muted" && tones(t).merged === "dim");
  const gone = badge({ phase: "gone", ref: "", ci: "" })[0];
  check("badge: a vanished checkout says gone, and clicking is handled", has(gone, "gone") && typeof gone.handlers.on_click === "function");
}

// --- tail: the default branch is hidden, the type dimmed ----------------------------------------
{
  fresh();
  const dir = "/code/att.owd/.git";
  const g = (branch, extra = {}) => ({ name: "ATT.OWD", branch, repo: JSON.stringify([null, dir]), ahead: 0, behind: 0, ...extra });
  const tail = (w, gg, tree = null) => rows.tail({ gitTail: (...a) => ({ host: a }) }, w, gg, tree, t);
  const w = { id: "s", name: "ATT.OWD" };
  phases.defaults[dir] = { at: 0, branch: "develop" };
  check("tail: the repository's own default branch is hidden", !has(tail(w, g("develop")), "develop"));
  check("tail: ...so main is shown when it is not the default", has(tail(w, g("main")), "main"));
  phases.defaults[dir] = { at: 0, branch: null };
  check("tail: an unknown default hides main and master", !has(tail(w, g("main")), "main") && !has(tail(w, g("master")), "master"));
  check("tail: ...and shows any other branch", has(tail(w, g("develop")), "develop"));
  delete phases.defaults[dir];
  check("tail: a repository never looked at behaves as unknown", !has(tail(w, g("main")), "main") && has(tail(w, g("develop")), "develop"));
  const remote = { ...g("develop"), repo: JSON.stringify(["vps", dir]) };
  phases.defaults[dir] = { at: 0, branch: "develop" };
  check("tail: another machine's repository does not use this one's default", has(tail(w, remote), "develop"));
  check("tail: a branch equal to the space's name is hidden", !has(tail({ id: "s", name: "feat/x" }, g("feat/x")), "feat/x"));
  const typed = tail(w, g("feature/dtx-machine-service"));
  check("tail: the type is dimmed and the rest muted", colorOf(holding(typed, "feature/")) === "dim"
    && colorOf(holding(typed, "dtx-machine-service")) === "muted");
  check("tail: a branch without a type is muted whole", colorOf(holding(tail(w, g("hotfix")), "hotfix")) === "muted");
  check("tail: the repository name is shown when the space has another name", texts(tail({ id: "s", name: "renamed" }, g("develop"))).some((s) => s.includes("ATT.OWD")));
  const counts = tail(w, g("develop", { ahead: 2, behind: 3 }));
  check("tail: ahead and behind are counts of their own", has(counts, "↑2") && has(counts, "↓3") && !has(tail(w, g("develop")), "↑0"));
  const nested = tail({ id: "s", name: "att.owd-fix-x" }, { ...g("fix/x"), name: "att.owd" }, "├─");
  check("tail: a nested worktree is the app's own tail, given the branch as its name when the label shows it",
    nested.host[2] === "fix/x" && nested.host[1] === "├─");
  const renamed = tail({ id: "s", name: "mine" }, g("fix/x"), "├─");
  check("tail: ...and its own name otherwise", renamed.host[2] === "mine");
}
