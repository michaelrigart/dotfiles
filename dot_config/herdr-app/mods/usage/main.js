// Claude and Codex usage at the right end of the status bar. The numbers come from the
// TUI's usage.sh, called read-only, so the parsing rules live in one place.
// Not while the window is hidden: the first tick after it shows again refreshes what fell due.

import { View } from "gpui-kit";
import { h_flex } from "gpui-base";
import { exec, home, theme, window } from "herdr";

const SCRIPT = ".config/herdr/usage.sh";
const TICK = 2000; // how often it checks whether a refresh is due; runs nothing unless it is
const EVERY = 60000;

export default class Usage extends View {
  init(_props, cx) {
    this.text = "";
    this.at = 0;
    cx.timer.every(TICK, (cx) => this.tick(cx));
    this.tick(cx);
  }

  tick(cx) {
    // The app keeps timers running while the window is hidden; null is no window (`herdr-app check`).
    if (window()?.visible === false || Date.now() - this.at < EVERY) return;
    this.at = Date.now();
    this.refresh(cx);
  }

  refresh(cx) {
    cx.spawn(async (cx) => {
      try {
        const r = await exec(`${home()}/${SCRIPT}`, [], { timeout: 5000 });
        // usage.sh ends on a Braille blank that insets the TUI's bar; it means nothing here.
        if (r.code === 0) this.text = r.stdout.replace(/[\s⠀]+$/, "");
      } catch {
        // Keep what it showed: a missed minute is not news.
      }
      cx.notify();
    });
  }

  render() {
    const t = theme();
    return h_flex().size_full().px(14).items_center().justify_end()
      .bg(t.chrome).border_t(1).border_color(t.border)
      .text_size(11.8).text_color(t.muted)
      .child(this.text);
  }
}
