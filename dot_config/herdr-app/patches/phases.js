// Where each worktree space sits between "I'm working on this" and "this is merged":
// active, draft, review or merged, with the pipeline result beside an open MR or PR.
// Only linked worktrees get a badge: a main checkout is nearly always dirty and would
// read permanently active.
// A space whose checkout folder no longer exists (wt-rm ran in a terminal, or somebody
// deleted it) shows "gone" instead, whatever it is: a click closes the space through the
// app's own close, which asks first. Nothing closes by itself.
//
// Source of truth: ~/.config/herdr-app/patches/phases.js. bin/respaces copies it into the
// michael-spaces clone of Herdr's `spaces` mod; edit it here, then run respaces. How the rows
// are drawn from this data (labels, folding, the tail) is rows.js.
//
// When it looks:
//   - at once when a repository's .git changes (a commit, a checkout, a push, a fetch);
//   - the forge again right after a remote ref moves, and every 15 s while a pipeline runs
//     or for two minutes after a push, otherwise every 60 s;
//   - local state at least every 60 s, for edits that touch nothing under .git.

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { spaces, panes, run, exec, home, appHome, notify, nextCommand, watchFolder } from "herdr";

const TICK = 2000; // how often it checks whether anything is due; runs nothing unless it is
const LOCAL = 60000; // local git state is read at least this often
const FORGE = 60000; // a forge answer stands this long
const HOT = 15000; // ...or this long while a pipeline runs or just after a push
const AFTER_PUSH = 120000; // how long a moved remote ref keeps its repository hot
const CALL = 20000; // one git, glab or gh call
const DEFAULT = 600000; // a repository's default branch is read again after this long

const GH_FAIL = ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"];
const GH_PEND = ["QUEUED", "IN_PROGRESS", "PENDING", "EXPECTED", "REQUESTED", "WAITING"];
const GH_GOOD = ["SUCCESS", "SKIPPED", "NEUTRAL"];
const GL_RUN = ["running", "pending", "created", "preparing", "waiting_for_resource", "scheduled"];

// One call per repository: open MRs with draft and their latest pipeline, and merged MRs,
// newest first. The latest pipeline, not `headPipeline`, which is empty when the newest
// commit has none of its own: this matches the REST head_pipeline the TUI badges show.
const GL_QUERY = `query($p: ID!) { project(fullPath: $p) {
  open: mergeRequests(state: opened, first: 100) { nodes { iid sourceBranch draft pipelines(first: 1) { nodes { status } } } }
  merged: mergeRequests(state: merged, first: 100) { nodes { iid sourceBranch } } } }`;

const out = (r) => (r.code === 0 ? r.stdout.replace(/\n$/, "") : null);
const json = (r) => {
  if (r.code !== 0) return null;
  try { return JSON.parse(r.stdout); } catch { return null; }
};

// "git@host:group/repo.git" or "https://host/group/repo(.git)" -> { host, slug, forge }.
// Only GitHub and GitLab have badges; another host (Azure DevOps) is never asked.
function remote(url) {
  const m = /^(?:[a-z+]+:\/\/)?(?:[^@/]+@)?([^:/]+)[:/](.+?)(?:\.git)?\/?$/.exec(url ?? "");
  if (!m) return null;
  const forge = m[1] === "github.com" ? "github" : /gitlab/.test(m[1]) ? "gitlab" : null;
  return forge ? { host: m[1], slug: m[2], forge, key: `${m[1]}/${m[2]}` } : null;
}

// A CheckRun's state is its conclusion once COMPLETED and its status before; a
// StatusContext's is its state. Fail beats pending, pending beats success.
function ghCi(rollup) {
  if (!Array.isArray(rollup) || !rollup.length) return "";
  const states = rollup.map((c) => (c?.state ?? (c?.status === "COMPLETED" ? c?.conclusion : c?.status)) ?? "");
  if (states.some((s) => GH_FAIL.includes(s))) return "fail";
  if (states.some((s) => GH_PEND.includes(s))) return "run";
  return states.every((s) => GH_GOOD.includes(s)) ? "ok" : "";
}

function glCi(status) {
  const s = String(status ?? "").toLowerCase();
  return s === "success" ? "ok" : s === "failed" ? "fail" : GL_RUN.includes(s) ? "run" : "";
}

// How a badge reads, on a row and in a folded repository's summary of the rows it hides.
// The colour says whether you have to act: red needs you (CI failed; "not wt", made outside
// wt), blue waits on others (review), yellow is in progress (CI running), green is passed;
// draft and merged are quiet. No other badge uses red, blue or yellow.
export const tones = (t) => ({ draft: t.muted, review: t.ansi4, merged: t.dim, "not wt": t.blocked });
export const marks = (t) => ({ ok: ["✓", t.ansi2], fail: ["✕", t.ansi1], run: ["◐", t.ansi3] });

export class Phases {
  // `cx`: the view's, for its timer; every later callback gets its own.
  constructor(cx) {
    this.by = {}; // space id -> { phase, ref, ci }
    this.forge = {}; // "host/slug" -> { at, mrs, running, hot }
    this.asking = {}; // "host/slug" -> the lookup in flight
    this.watching = new Set(); // git common dirs with a watch
    this.forgeOf = {}; // git common dir -> "host/slug"
    this.warned = new Set(); // spaces already reported as made outside wt
    this.dirty = false;
    this.seen = "";
    this.at = 0;
    this.defaults = {}; // git common dir -> { at, branch }: origin's default branch, null when unknown
    cx.timer.every(TICK, (cx) => this.tick(cx));
    this.tick(cx);
    // "michael-spaces.refresh" in keys.json: look everything up now, whatever the TTL. For
    // right after merging in the browser.
    cx.spawn(async (cx) => {
      for (;;) {
        if ((await nextCommand()) !== "refresh") continue;
        this.forced = true;
        this.tick(cx);
      }
    });
  }

  places() {
    const ps = panes();
    return spaces().filter((s) => !s.machine).map((s) => {
      const tabs = new Set((s.tabs ?? []).map((t) => t.id));
      return { id: s.id, name: s.name, folder: s.folder, cwd: ps.find((p) => tabs.has(p.tab) && p.cwd)?.cwd || s.folder, branch: s.branch };
    }).filter((p) => p.cwd);
  }

  ttl(f, now) {
    return f.running || now < f.hot ? HOT : FORGE;
  }

  tick(cx) {
    if (this.busy) return;
    const now = Date.now();
    const places = this.places();
    const seen = JSON.stringify(places);
    const forgeDue = Object.values(this.forge).some((f) => now - f.at >= this.ttl(f, now));
    if (!this.forced && !this.dirty && !forgeDue && seen === this.seen && now - this.at < LOCAL) return;
    const forced = this.forced;
    this.forced = false;
    // Cleared before the look, so a change during it is looked at again.
    this.dirty = false;
    if (forced) for (const f of Object.values(this.forge)) f.at = 0;
    this.busy = true;
    this.seen = seen;
    cx.spawn(async (cx) => {
      try {
        this.used = { dirs: new Set(), keys: new Set() };
        const rows = await Promise.all(places.map(async (p) =>
          (await this.vanished(p.folder)) ? { id: p.id, phase: "gone", ref: "", ci: "" } : this.row(p, cx).catch(() => null)));
        this.by = Object.fromEntries(rows.filter(Boolean).map((r) => [r.id, r]));
        // Repositories no space shows any more: no watch, no forge lookups.
        for (const dir of this.watching) if (!this.used.dirs.has(dir)) this.watching.delete(dir);
        for (const key of Object.keys(this.forge)) if (!this.used.keys.has(key)) delete this.forge[key];
        if (forced) notify({ title: "Phases refreshed", timeout: 1500 });
      } finally {
        this.at = Date.now();
        this.busy = false;
        cx.notify();
      }
    });
  }

  // The folder the space was made at is positively gone (bin/folder-gone: ENOENT). A folder
  // that cannot be checked (no permission, an unmounted volume), or a check that cannot run,
  // says nothing: never "gone".
  async vanished(folder) {
    if (!folder) return false;
    try { return (await exec(`${appHome()}/bin/folder-gone`, [folder], { timeout: CALL })).code === 0; } catch { return false; }
  }

  // Origin's default branch (refs/remotes/origin/HEAD), read from refs only, at most once per
  // repository per DEFAULT however many of its spaces ask. A failed read keeps what was known.
  async defaultOf(dir, git) {
    const known = this.defaults[dir];
    const now = Date.now();
    if (known && now - known.at < DEFAULT) return;
    this.defaults[dir] = { at: now, branch: known?.branch ?? null };
    const b = out(await git("symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"));
    if (b) this.defaults[dir].branch = b.replace(/^origin\//, "");
  }

  // One watch per repository (every worktree's refs and HEAD live under the common dir).
  watch(dir, cx) {
    if (this.watching.has(dir)) return;
    this.watching.add(dir);
    cx.spawn(async () => {
      try {
        while (this.watching.has(dir)) {
          const paths = await watchFolder(dir);
          if (!this.watching.has(dir)) return;
          // A remote ref moving is a push or a fetch: the forge has news too, soon.
          if (paths.some((p) => p === dir || p.includes("/refs/remotes/") || p.endsWith("/packed-refs"))) {
            const f = this.forge[this.forgeOf[dir]];
            if (f) { f.at = 0; f.hot = Date.now() + AFTER_PUSH; }
          }
          // Objects and reflogs move on their own (gc, fetch); refs, HEAD and the index
          // are what a row reads.
          if (paths.some((p) => !p.includes("/objects/") && !p.includes("/logs/"))) this.dirty = true;
        }
      } catch {
        this.watching.delete(dir);
      }
    });
  }

  async row(p, cx) {
    const git = (...args) => exec("git", args, { cwd: p.cwd, timeout: CALL });
    const [top, common] = await Promise.all([
      git("rev-parse", "--path-format=absolute", "--show-toplevel"),
      git("rev-parse", "--path-format=absolute", "--git-common-dir"),
    ]);
    if (top.code !== 0 || common.code !== 0) return null;
    const dir = out(common);
    await this.defaultOf(dir, git);
    if (dir === `${out(top)}/.git`) return null;
    this.used.dirs.add(dir);
    this.watch(dir, cx);
    // The app's own New worktree puts checkouts here, past everything wt does (the sibling
    // folder, .worktreehook, .worktreeinclude, the lock), and nothing can redirect it.
    if (out(top).startsWith(`${home()}/.herdr/worktrees/`)) {
      if (!this.warned.has(p.id)) {
        this.warned.add(p.id);
        notify({ title: "Worktree made outside wt", body: `${p.name} was created by the app's New worktree, not by wt.`, level: "warning" });
      }
      return { id: p.id, phase: "not wt", ref: "", ci: "" };
    }
    const branch = out(await git("symbolic-ref", "--short", "-q", "HEAD"));
    if (!branch) return null;

    const where = remote(out(await git("remote", "get-url", "origin")));
    if (where) { this.forgeOf[dir] = where.key; this.used.keys.add(where.key); }
    const mr = where ? (await this.mrs(where, p.cwd))[branch] : null;
    const row = { id: p.id, phase: "active", ref: "", ci: "" };

    // An open MR outranks everything git can see locally: somebody else is waiting on it.
    if (mr?.state === "open") return { ...row, phase: mr.draft ? "draft" : "review", ref: mr.ref, ci: mr.ci };
    // Local work outranks a merged MR: once landed, new work in that worktree is new work.
    // --no-optional-locks: a status that refreshed the index would wake the watch above.
    if (out(await git("--no-optional-locks", "status", "--porcelain"))) return row;
    const base = out(await git("symbolic-ref", "--short", "refs/remotes/origin/HEAD")) || "origin/main";
    const pushed = (await git("rev-parse", "--verify", "--quiet", `origin/${branch}`)).code === 0;
    const ahead = Number(out(await git("rev-list", "--count", `${pushed ? `origin/${branch}` : base}..HEAD`)) ?? 0);
    if (ahead > 0) return row;
    // Only a merged MR is evidence that something landed: a new worktree is contained in
    // the base too, and a squash merge is never an ancestor.
    return mr?.state === "merged" ? { ...row, phase: "merged", ref: mr.ref } : row;
  }

  // The repo's open and merged MRs or PRs by branch, once per repository however many of
  // its worktrees ask at the same time.
  async mrs(where, cwd) {
    const hit = this.forge[where.key];
    const now = Date.now();
    if (hit && now - hit.at < this.ttl(hit, now)) return hit.mrs;
    this.asking[where.key] ??= this.ask(where, cwd).finally(() => delete this.asking[where.key]);
    const mrs = await this.asking[where.key];
    // A failed lookup keeps what it had, and is tried again on the next tick.
    if (!mrs) return hit?.mrs ?? {};
    this.forge[where.key] = {
      at: Date.now(), mrs, hot: hit?.hot ?? 0,
      running: Object.values(mrs).some((m) => m.ci === "run"),
    };
    return mrs;
  }

  // An open one beats a merged one on the same branch; the newest of each state counts.
  async ask({ host, slug, forge }, cwd) {
    const mrs = {};
    const call = (cmd, args) => exec(cmd, args, { cwd, timeout: CALL }).then(json).catch(() => null);
    if (forge === "github") {
      const fields = "headRefName,number,isDraft,isCrossRepository";
      const ask = (state, extra) => call("gh", ["pr", "list", "-R", `${host}/${slug}`, "--state", state, "--limit", "100", "--json", fields + extra]);
      const [open, merged] = await Promise.all([ask("open", ",statusCheckRollup"), ask("merged", "")]);
      if (!Array.isArray(open)) return null;
      for (const pr of (Array.isArray(merged) ? merged : []).filter((pr) => !pr.isCrossRepository)) mrs[pr.headRefName] ??= { state: "merged", ref: `#${pr.number}` };
      for (const pr of open.filter((pr) => !pr.isCrossRepository).reverse()) mrs[pr.headRefName] = { state: "open", ref: `#${pr.number}`, draft: pr.isDraft === true, ci: ghCi(pr.statusCheckRollup) };
      return mrs;
    }
    const r = await call("glab", ["api", "graphql", "--hostname", host, "-f", `query=${GL_QUERY}`, "-f", `p=${slug}`]);
    const project = r?.data?.project;
    if (!project || r.errors) return null;
    for (const m of project.merged?.nodes ?? []) mrs[m.sourceBranch] ??= { state: "merged", ref: `!${m.iid}` };
    for (const m of (project.open?.nodes ?? []).slice().reverse()) {
      mrs[m.sourceBranch] = { state: "open", ref: `!${m.iid}`, draft: m.draft === true, ci: glCi(m.pipelines?.nodes?.[0]?.status) };
    }
    return mrs;
  }

  // What a space's row ends on: nothing, or one element.
  badge(id, t) {
    const r = this.by[id];
    if (!r) return [];
    if (r.phase === "gone") {
      return [div().id(`gone-${id}`).flex_none().px(5).rounded(4).text_size(11.5).text_color(t.blocked)
        .cursor_pointer().hover((s) => s.bg(t.hover)).tooltip("The checkout folder is gone: click to close this space")
        // space.close asks first. The row's own press would also select the space.
        .on_click((_e, cx) => { cx.stop_propagation(); run("space.close", { id }); })
        .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
        .child("gone")];
    }
    // Active (no MR yet) says nothing: nearly every worktree is, and ● is the machine status's.
    if (r.phase === "active") return [];
    const tone = tones(t);
    const ci = marks(t)[r.ci];
    const text = r.ref ? `${r.phase} ${r.ref}` : r.phase;
    return [h_flex().flex_none().gap(5).items_center().text_size(11.5)
      .child(div().text_color(tone[r.phase]).child(text))
      .when(Boolean(ci), (el) => el.child(div().text_color(ci[1]).child(ci[0])))];
  }
}
