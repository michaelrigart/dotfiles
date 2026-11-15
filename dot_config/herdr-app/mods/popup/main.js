// The TUI's popups, for the app. Draws nothing; keys.json and the space menu send it:
//   popup.lazygit      alt+g          lazygit, 90% x 90%
//   popup.scratch      alt+p          a scratch shell, 80% x 80%
//   popup.scrollback   alt+s          the focused terminal's scrollback in Neovim, 90% x 90%
//   popup.wt           cmd+shift+g    `wt` asking for a branch, 60% x 40% (and the space
//                                     menu's New worktree)
//
// Each is a terminal the core runs that no space holds, shown in a modal dialog over the window.
// The dialog closes by itself when its terminal ends, so a popup lasts as long as its program.
// Esc goes to the program (Neovim and lazygit need it), and `modal` keeps a click beside the
// dialog from closing it.
//
// The core runs it on this computer, so in a space on another machine lazygit and scratch open
// a tab there, as before. Scrollback and wt still run here, from the home folder.

import { View, div } from "gpui-kit";
import { spaces, focused, run, hc, home, appHome, notify, openOverlay, nextCommand } from "herdr";

// The person's interactive login shell around the program, as the app does for a tab's argv:
// a repository's mise tools reach lazygit's git hooks, and wt finds what it does in a tab.
const LOGIN = ["/bin/sh", "-c", 'exec "${SHELL:-/bin/zsh}" -lic \'exec "$@"\' popup "$@"', "sh"];

const COMMANDS = ["lazygit", "scratch", "scrollback", "wt"];

export default class Popup extends View {
  init(_props, cx) {
    // One at a time and in order: a second press while one is opening must not race it.
    cx.spawn(async (cx) => {
      for (;;) {
        const c = await nextCommand();
        try {
          if (COMMANDS.includes(c)) await this[c](cx);
        } catch (e) {
          notify({ title: `Popup ${c} failed`, body: String(e?.message ?? e), level: "warning" });
        }
      }
    });
  }

  // lazygit and scratch start where the focused terminal is now, else at the space's folder.
  async lazygit(cx) {
    return this.here(["lazygit"], "lazygit", 0.9, cx);
  }

  async scratch(cx) {
    return this.here([], "scratch", 0.8, cx);
  }

  async here(argv, name, size, cx) {
    const space = spaces().find((s) => s.active);
    if (space?.machine) return run("terminal.open", { ...(argv.length ? { argv } : {}), name });
    return this.show(argv, focused()?.cwd || space?.folder || home(), size, size, cx);
  }

  async scrollback(cx) {
    const f = focused();
    if (!f?.terminal) return;
    // A machine prefix ("hercules/t3") means the terminal is not on this computer, and neither
    // is its folder.
    const cwd = f.terminal.includes("/") ? null : f.cwd;
    return this.show([`${appHome()}/bin/edit-scrollback`, f.terminal], cwd || home(), 0.9, 0.9, cx);
  }

  async wt(cx) {
    // The space's own folder, not a pane's live one, which may have wandered into another checkout.
    const space = spaces().find((s) => s.active);
    const cwd = space && !space.machine && space.folder ? space.folder : home();
    return this.show([`${appHome()}/bin/wt-app`, "--prompt"], cwd, 0.6, 0.4, cx);
  }

  async show(argv, cwd, width, height, cx) {
    // Without --cwd the terminal starts where the app does.
    const r = await hc(["run", "--bg", "--rm", "--json", "--no-parent", "--no-notify", "--cwd", cwd,
      ...(argv.length ? ["--", ...LOGIN, ...argv] : [])]);
    let address = null;
    try { address = JSON.parse(r.stdout).address; } catch {}
    if (r.code !== 0 || !address) throw new Error(r.stderr.trim() || "no terminal address");
    openOverlay({ kind: "dialog", modal: true, width, height, layout: { type: "block", content: { terminal: address } } });
    // The terminal should hold the keyboard; when the app has not handed it over after a moment, ask once.
    await new Promise((done) => cx.timer.after(50, () => done()));
    if (focused()?.terminal !== address) run("pane.focus", { terminal: address });
  }

  render() {
    return div();
  }
}
