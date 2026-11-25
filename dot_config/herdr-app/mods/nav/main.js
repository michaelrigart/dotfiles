// The TUI's movement keys, for the app. Draws nothing; keys.json sends it:
//   nav.left|down|up|right   ctrl+h/j/k/l: Neovim's own splits first, then the app's panes,
//                            and the key itself when there is nowhere to go (so a shell's
//                            ctrl+h and ctrl+l still work beside an edge)
//   nav.agents|runtime       alt+a / alt+r: the space's tab of that name
//   nav.editor               alt+e: the editor tab, made with `nvim .` the first time
// Cmd-click on path:line opens it in that tab's Neovim, making the tab when there is none: link.js.
//
// Neovim needs no plugin or config for this: its server answers whether the cursor is at
// a split edge, and only then does the key leave it. smart-splits finds no multiplexer in
// the app's terminals, so inside Neovim it keeps moving between splits as before.

import { View, div } from "gpui-kit";
import { spaces, panes, focused, run, exec, hc, notify, nextCommand } from "herdr";
import { vimIn, serverOf, makeEditor } from "./nvim.js";

const DIRS = { left: ["h", "ctrl+h"], down: ["j", "ctrl+j"], up: ["k", "ctrl+k"], right: ["l", "ctrl+l"] };
const TABS = ["agents", "runtime", "editor"];

export default class Nav extends View {
  init(_props, cx) {
    this.sockets = {}; // terminal -> its Neovim's server socket
    // One at a time and in order: two quick presses must move twice, not race.
    cx.spawn(async (cx) => {
      for (;;) {
        const c = await nextCommand();
        try {
          if (DIRS[c]) await this.move(c, cx);
          else if (TABS.includes(c)) this.tab(c);
        } catch {}
      }
    });
  }

  async socket(terminal, pid) {
    const hit = this.sockets[terminal];
    if (hit?.pid === pid) return hit.path;
    const path = await serverOf(pid);
    if (path) this.sockets[terminal] = { pid, path };
    return path;
  }

  // true: Neovim is in normal mode with the cursor at that edge, so the key leaves it.
  // false: Neovim takes the key. null: no Neovim answered.
  async leaves(terminal, pid, w) {
    const path = await this.socket(terminal, pid);
    if (!path) return null;
    const r = await exec("nvim", ["--server", path, "--remote-expr", `mode() ==# 'n' && winnr('${w}') == winnr()`], { timeout: 2000 });
    if (r.code !== 0 || !/^[01]$/.test(r.stdout.trim())) { delete this.sockets[terminal]; return null; }
    return r.stdout.trim() === "1";
  }

  key(terminal, key) {
    return hc(["keys", terminal, key]);
  }

  // The app reports a move's new focus a moment after the command: wait for it, and only
  // when none comes is there no pane in that direction.
  async moved(from, cx) {
    for (let waited = 0; waited < 200; waited += 20) {
      await new Promise((done) => cx.timer.after(20, () => done()));
      if (focused()?.pane !== from) return true;
    }
    return false;
  }

  async move(dir, cx) {
    const [w, key] = DIRS[dir];
    const f = focused();
    const terminal = f?.terminal ?? null;
    const pane = f?.pane ? panes().find((p) => p.pane === f.pane) : null;
    // The pane's program is the app's guess and costs nothing; ask the core only when it
    // says Vim, or knows nothing.
    const maybe = !pane?.program || pane.program.shell === false;
    const pid = terminal && maybe ? await vimIn(terminal) : null;
    if (pid) {
      const leave = await this.leaves(terminal, pid, w);
      if (leave !== true) return this.key(terminal, key);
    }
    if (!f?.pane) return terminal ? this.key(terminal, key) : null;
    run("pane.go", { direction: dir });
    if (!(await this.moved(f.pane, cx)) && terminal) return this.key(terminal, key);
  }

  tab(name) {
    const s = spaces().find((x) => x.active);
    if (!s) return;
    const t = (s.tabs ?? []).find((x) => x.name === name);
    if (t) return run("tab.select", { id: t.id });
    // agents and runtime come with the space (open-space): one that is missing is news,
    // not something a jump should quietly rebuild.
    if (name !== "editor") return notify({ title: `No ${name} tab in ${s.name}`, level: "warning", timeout: 2500 });
    makeEditor(s.id, s.folder || focused()?.cwd, ["nvim", "."]);
  }

  render() {
    return div();
  }
}
