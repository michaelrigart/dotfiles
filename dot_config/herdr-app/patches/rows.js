// How the spaces pane draws its rows, apart from the phase and forge data behind them (phases.js):
// a nested worktree labelled by its branch with the type dimmed, the tail after a name, a
// repository's worktrees folded away (with a marker for the most urgent hidden state), and
// merged worktrees last.
//
// Source of truth: ~/.config/herdr-app/patches/rows.js. bin/respaces copies it into the
// michael-spaces clone of Herdr's `spaces` mod, next to phases.js; edit it here, then run respaces.

import { div, svg } from "gpui-kit";
import { h_flex } from "gpui-base";
import { tones, marks } from "./phases.js";

const SIDE_MIN = 48; // the spaces mod's own minimum for a row's tail

export class Rows {
  // `phases`: the view's Phases, for the phase and default-branch data each row is drawn from.
  constructor(phases) {
    this.phases = phases;
    this.kids = {}; // repo -> how many worktree spaces sit under it, folded or not
    this.owner = {}; // repo -> the space whose row they follow (and which carries the fold toggle)
    this.under = {}; // repo -> the worktree spaces under it
    try { this.hidden = new Set(JSON.parse(localStorage.getItem("repos.folded") ?? "[]")); } catch { this.hidden = new Set(); }
  }

  // A worktree row under its repository: the branch is the label when the space still has the
  // name wt gave it (bin/open-space names it after the checkout folder, `<repo>-<branch with /
  // as ->`), so the name and the branch are not both shown. A renamed space keeps its name.
  // Returns the branch, or null to leave the row as it is.
  asBranch(w, g, tree) {
    if (!tree || !g?.branch || g.branch === "(detached)") return null;
    const name = w.name.toLowerCase();
    const automatic = [g.branch, `${g.name}-${g.branch.replaceAll("/", "-")}`];
    return automatic.some((a) => a.toLowerCase() === name) ? g.branch : null;
  }

  // The row's name: the branch with its type (fix/, feat/, ...) dimmed, or the space's name.
  // A merged worktree is finished and only waits for wt-rm, so its name is muted as well.
  label(w, g, tree, t) {
    const branch = this.asBranch(w, g, tree);
    const merged = this.phases.by[w.id]?.phase === "merged";
    const cut = branch ? branch.indexOf("/") + 1 : 0;
    if (!merged && !cut) return branch ?? w.name;
    const name = (text) => (merged ? div().min_w(0).truncate().text_color(t.muted).child(text) : div().min_w(0).truncate().child(text));
    if (!cut) return name(branch ?? w.name);
    return h_flex().min_w(0)
      .child(div().flex_none().text_color(t.dim).child(branch.slice(0, cut)))
      .child(name(branch.slice(cut)));
  }

  // The tail after a row's name. A nested worktree: the mod's own gitTail, given the branch as
  // its name when the label already shows it. Any other row: the same thing drawn here, with the
  // branch's type (feature/, fix/, ...) dimmed, and the repository's own default branch hidden
  // (main and master only while it is unknown). Keep in step with the spaces mod's gitTail:
  // the gitTail digest check in bin/patch-mod stops respaces when Herdr changes that method, so
  // this copy is brought up to date (and the digest with it) instead of drifting.
  tail(host, w, g, tree, t) {
    if (tree) return host.gitTail(g, tree, this.asBranch(w, g, tree) ?? w.name, t);
    const raw = g.branch ?? "detached";
    const [on, dir] = JSON.parse(g.repo);
    const known = on ? null : this.phases.defaults[dir]?.branch;
    const same = (a) => a.toLowerCase() === w.name.toLowerCase();
    const hide = same(raw) || (known ? raw === known : raw === "main" || raw === "master");
    const repo = same(g.name) ? "" : g.name;
    const cut = raw.indexOf("/") + 1;
    const text = (s, c) => div().min_w(0).truncate().text_color(c).child(s);
    return h_flex().flex_auto().min_w(repo || !hide ? SIDE_MIN : 0).gap(5).justify_end().items_center().text_size(11.5).text_color(t.dim)
      .when(Boolean(repo), (el) => el.child(text(hide ? repo : `${repo} ·`, t.dim)))
      .when(!hide && Boolean(cut), (el) => el.child(h_flex().min_w(0).gap(0)
        .child(div().flex_none().text_color(t.dim).child(raw.slice(0, cut)))
        .child(text(raw.slice(cut), t.muted))))
      .when(!hide && !cut, (el) => el.child(text(raw, t.muted)))
      .when(g.ahead > 0, (el) => el.child(div().flex_none().text_color(t.ansi2).child(`↑${g.ahead}`)))
      .when(g.behind > 0, (el) => el.child(div().flex_none().text_color(t.ansi1).child(`↓${g.behind}`)));
  }

  // The rows the list draws: a folded repository's worktree spaces are left out. The narrow
  // rail has no toggle, so it keeps them. Also notes, per repository, how many worktrees
  // follow which row.
  fold(rows, rail) {
    this.kids = {};
    this.owner = {};
    this.under = {};
    let last = null;
    for (const r of rows) {
      if (!r.tree) { last = r; continue; }
      this.kids[r.g.repo] = (this.kids[r.g.repo] ?? 0) + 1;
      (this.under[r.g.repo] ??= []).push(r.w);
      if (last) this.owner[r.g.repo] = last.w.id;
    }
    if (rail) return rows;
    return this.mergedLast(rows).filter((r) => !r.tree || !this.hidden.has(r.g.repo));
  }

  // Under each repository the merged worktrees come last (they only wait for wt-rm), the rest
  // and the merged ones each in their stored order. Only what is drawn: the order Herdr keeps,
  // and space.move works from, is not touched.
  mergedLast(rows) {
    const merged = (r) => this.phases.by[r.w.id]?.phase === "merged";
    const out = [];
    for (let i = 0; i < rows.length;) {
      if (!rows[i].tree) { out.push(rows[i++]); continue; }
      let end = i;
      while (end < rows.length && rows[end].tree) end++;
      const run = rows.slice(i, end);
      out.push(...run.filter((r) => !merged(r)), ...run.filter(merged));
      i = end;
    }
    return out;
  }

  // An agent in the space waits for you ("blocked": the same state the Agents list calls
  // "Needs you"). The app keeps it on the space, so this reads nothing more.
  waiting(w) {
    return w.status === "blocked";
  }

  // What needs you in a space: [glyph, colour, what it says], red like a failed CI but a "!".
  waitingMark(t) {
    return ["!", t.blocked, "An agent is waiting for you"];
  }

  // What stands out among a folded repository's hidden worktrees, as [glyph, colour, what it
  // says] marks, most urgent first: what needs you (an agent waiting, CI failed), then a review
  // waiting, then the space you are in. Empty when none.
  urgent(repo, t) {
    const hidden = this.under[repo] ?? [];
    const by = hidden.map((w) => this.phases.by[w.id]).filter(Boolean);
    const needs = [];
    if (hidden.some((w) => this.waiting(w))) needs.push(this.waitingMark(t));
    if (by.some((r) => r.ci === "fail")) needs.push([...marks(t).fail.slice(0, 2), "A hidden worktree's CI failed"]);
    if (needs.length) return needs;
    if (by.some((r) => r.phase === "review")) return [["review", tones(t).review, "A hidden worktree waits for review"]];
    if (hidden.some((w) => w.active)) return [["◆", t.foreground, "The space you are in is hidden"]];
    return [];
  }

  // The fold toggle on the row a repository's worktrees follow: a chevron, and how many are
  // hidden while folded, with the most urgent state among them.
  toggle(id, t) {
    const repo = Object.keys(this.owner).find((k) => this.owner[k] === id);
    const n = this.kids[repo];
    if (!n) return [];
    const folded = this.hidden.has(repo);
    const flags = folded ? this.urgent(repo, t) : [];
    return [h_flex().id(`fold-${id}`).flex_none().gap(4).px(4).items_center().rounded(4).text_size(11.5).text_color(t.dim)
      .cursor_pointer().hover((s) => s.bg(t.hover).text_color(t.foreground))
      .tooltip(folded ? `Show ${n} worktree${n === 1 ? "" : "s"}${flags.map((f) => `. ${f[2]}`).join("")}` : "Hide worktrees")
      .children(flags.map((f) => div().text_color(f[1]).child(f[0])))
      .on_click((_e, cx) => {
        cx.stop_propagation();
        folded ? this.hidden.delete(repo) : this.hidden.add(repo);
        try { localStorage.setItem("repos.folded", JSON.stringify([...this.hidden])); } catch {}
        cx.notify();
      })
      .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
      .when(folded, (el) => el.child(String(n)))
      .child(svg(`mods/workspace-chrome/chevron-${folded ? "right" : "down"}.svg`).size(11).flex_none())];
  }

  // Everything a space's row ends on: a "!" when an agent in it waits for you, its phase badge,
  // and the fold toggle on a repository's row.
  end(w, t) {
    const mark = this.waiting(w) ? this.waitingMark(t) : null;
    return [
      ...(mark ? [div().id(`waiting-${w.id}`).flex_none().text_size(11.5).font_bold().text_color(mark[1]).tooltip(mark[2]).child(mark[0])] : []),
      ...this.phases.badge(w.id, t),
      ...this.toggle(w.id, t),
    ];
  }
}
