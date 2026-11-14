// Bring agent sessions back after a restart. herdr-core gives a lost terminal a shell in
// its last folder and never runs its command again, so this remembers, per terminal, the
// command that resumes the exact session there, and which core it was running under.
// A terminal back at a bare shell under a different core was lost in a restart: it is
// resumed at once. One back at a shell under the same core had its agent quit on purpose:
// that only gets the button in the status bar (or "resume.all" from keys.json).
//
// No agent hooks. The session id comes from what each agent already publishes:
//   Claude Code  ~/.claude/sessions/<pid>.json, its own registry of running sessions
//   Codex        the terminal title, which carries the session id
// and the flags from the running process, so a read-only Codex comes back read-only.

import { View, div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { panes, machines, hc, exec, readTextFile, home, appHome, shared, setShared, theme, notify, nextCommand } from "herdr";

const TICK = 1500; // how often it looks whether any pane changed (no process is run)
const EVERY = 10000; // how often it asks the core anyway
const SHELLS = ["zsh", "bash", "fish", "sh", "dash", "ksh"];
const KEY = "resume.sessions"; // terminal address -> { app, id, cwd, cmd, fresh }
const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;
// Two looks at the same core differ in start time only by rounding.
const sameCore = (a, b) => Boolean(a && b) && a.pid === b.pid && Math.abs(a.start - b.start) < 5000;
// Shells the core has just recovered may not read typed input yet.
const SETTLE = 3000;
const quote = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

// argv without the program and without any earlier way of naming a session.
function flags(argv, drop) {
  const out = [];
  for (let i = 1; i < argv.length; i++) {
    if (drop.bare.includes(argv[i])) continue;
    if (drop.valued.includes(argv[i])) { i++; continue; }
    out.push(argv[i]);
  }
  return out;
}

async function coreNow() {
  try {
    const s = JSON.parse((await hc(["server", "status", "--json"])).stdout);
    return Number.isInteger(s?.pid) && Number.isFinite(s?.uptime_ms) ? { pid: s.pid, start: Date.now() - s.uptime_ms } : null;
  } catch {
    return null;
  }
}

async function get(address) {
  try {
    const r = await hc(["get", address, "--json"]);
    return r.code === 0 ? JSON.parse(r.stdout) : null;
  } catch {
    return null;
  }
}

// The command that resumes what runs in a terminal now, or null when it can't be told.
async function record(t) {
  const fg = t?.foreground;
  if (!fg?.argv?.length) return null;
  const cwd = fg.cwd || t.cwd;
  if (fg.name === "claude") {
    let id;
    try { id = JSON.parse(await readTextFile(`${home()}/.claude/sessions/${fg.pid}.json`))?.sessionId; } catch {}
    if (!UUID.test(id ?? "")) return null;
    const rest = flags(fg.argv, { bare: ["-c", "--continue"], valued: ["-r", "--resume", "--session-id"] });
    return { app: "claude", id, cwd, fresh: ["claude", ...rest].map(quote).join(" "),
      cmd: ["claude", ...rest, "--resume", id].map(quote).join(" ") };
  }
  if (fg.name === "codex") {
    const id = UUID.exec(t.title ?? "")?.[0];
    if (!id) return null;
    // `codex`, not the versioned binary in argv[0]: an upgrade moves that path. A session
    // that was itself resumed has "resume <id>" in its argv already.
    const rest = flags(fg.argv, { bare: ["resume", "--last"], valued: [] }).filter((a) => !UUID.test(a));
    return { app: "codex", id, cwd, fresh: ["codex", ...rest].map(quote).join(" "),
      cmd: ["codex", "resume", ...rest, id].map(quote).join(" ") };
  }
  return null;
}

// Neither agent writes a session to disk before its first message, and resuming one that
// was never written fails ("no conversation found"). Such a session has nothing to bring
// back: the terminal gets the same agent, started fresh. The rule is bin/session-written,
// which bin/retire uses too.
let warnedWritten = false;
async function written({ app, id }) {
  try {
    return (await exec(`${appHome()}/bin/session-written`, [app, id], { timeout: 10000 })).code === 0;
  } catch {
    // The helper did not run at all (missing, not executable), which is not "not written":
    // every session would silently start fresh. Said once per run.
    if (!warnedWritten) {
      warnedWritten = true;
      notify({ title: "Cannot tell whether agent sessions were saved", body: "bin/session-written did not run: sessions start fresh.", level: "warning" });
    }
    return false;
  }
}

export default class Resume extends View {
  init(_props, cx) {
    this.lost = []; // remembered terminals that are back at a bare shell
    this.sig = "";
    this.at = 0;
    cx.timer.every(TICK, (cx) => this.tick(cx));
    this.tick(cx);
    cx.spawn(async (cx) => {
      for (;;) if ((await nextCommand()) === "all") this.restore(cx);
    });
  }

  // An agent starting or quitting changes its pane's title, program or status, so a
  // change there is the moment to ask the core; a quit then shows within a tick or two.
  tick(cx) {
    if (this.busy) return;
    const sig = JSON.stringify(panes().map((p) => [p.terminal, p.title, p.program?.key, p.status]));
    if (!this.again && sig === this.sig && Date.now() - this.at < EVERY) return;
    this.again = false;
    this.sig = sig;
    this.at = Date.now();
    this.scan(cx);
  }

  scan(cx) {
    this.busy = true;
    cx.spawn(async (cx) => {
      try {
        const saved = { ...(shared(KEY) ?? {}) };
        const core = await coreNow();
        // This computer's terminals only: a remote address carries its machine's name.
        const local = panes().filter((p) => p.terminal && !p.terminal.includes("/"));
        const live = new Set(local.map((p) => p.terminal));
        let changed = false;
        // Forget a terminal only once this computer's layout has loaded: right after a
        // start there are no panes yet, and that must not read as "every terminal is gone".
        if (machines().find((m) => m.name === null)?.layout === "ready") {
          for (const address of Object.keys(saved)) {
            if (!live.has(address)) { delete saved[address]; changed = true; }
          }
        }
        // The pane's own `program` is no guide here: it keeps an agent's last report after
        // the agent has quit, and has none for a Claude that never reported. What runs in
        // the terminal now is asked of the core, for every pane that could matter, at once.
        const asked = local.filter((p) => !(p.program?.shell && !saved[p.terminal]));
        const seen = await Promise.all(asked.map(async (p) => {
          const t = await get(p.terminal);
          const running = t?.foreground?.name ?? "";
          if (SHELLS.includes(running.replace(/^-/, ""))) return { address: p.terminal, shell: true };
          return { address: p.terminal, now: await record(t) };
        }));
        const lost = [], restarted = [];
        for (const { address, shell, now } of seen) {
          const rec = saved[address];
          if (shell) {
            if (rec) (core && rec.core && !sameCore(rec.core, core) ? restarted : lost).push(address);
            continue;
          }
          if (now && (now.cmd !== rec?.cmd || (core && !sameCore(rec?.core, core)))) {
            saved[address] = { ...now, core };
            changed = true;
          }
        }
        let auto = [];
        if (restarted.length) {
          if (Date.now() - core.start < SETTLE) {
            this.again = true; // look again on the next tick, once the shells are up
          } else {
            // Claimed for this core before sending: a resume that fails leaves the button,
            // never a loop of retries.
            for (const address of restarted) saved[address] = { ...saved[address], core };
            changed = true;
            auto = restarted;
          }
        }
        if (changed) setShared(KEY, saved);
        this.lost = lost;
        if (auto.length) this.restore(cx, auto);
      } finally {
        this.busy = false;
        cx.notify();
      }
    });
  }

  // `auto`: the terminals a restart lost, resumed without a click; else the button's.
  restore(cx, auto) {
    const saved = shared(KEY) ?? {};
    const lost = (auto ?? this.lost).filter((address) => saved[address]);
    if (!lost.length) return auto ? null : notify({ title: "No agent sessions to resume", timeout: 2000 });
    if (this.resuming) return;
    this.resuming = true;
    cx.notify();
    cx.spawn(async (cx) => {
      // All at once: each send waits on its own terminal, not on the one before it.
      const sent = await Promise.all(lost.map(async (address) => {
        const rec = saved[address];
        try {
          return (await hc(["send", address, `cd ${quote(rec.cwd)} && ${(await written(rec)) ? rec.cmd : rec.fresh}`])).code === 0;
        } catch {
          return false;
        }
      }));
      const failed = sent.filter((ok) => !ok).length;
      const what = `${lost.length - failed}${failed ? ` of ${lost.length}` : ""} agent ${lost.length === 1 ? "session" : "sessions"}`;
      if (failed) notify({ title: `Resumed ${what}`, level: "warning" });
      else if (auto) notify({ title: `Resumed ${what} after a restart`, timeout: 3000 });
      if (!auto) this.lost = [];
      this.resuming = false;
      cx.notify();
    });
  }

  render() {
    const t = theme();
    const n = this.lost.length;
    return h_flex().size_full().px(10).items_center().justify_end()
      .bg(t.chrome).border_t(1).border_color(t.border).text_size(11.8)
      .when(this.resuming, (el) => el.child(h_flex().gap(6).px(6).text_color(t.muted)
        .child(div().frames(["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"], 90)).child("resuming…")))
      .when(n > 0 && !this.resuming, (el) => el.child(
        div().id("resume-all").px(6).rounded(4).text_color(t.accent).cursor_pointer()
          .hover((s) => s.bg(t.hover))
          .on_click((_e, cx) => this.restore(cx))
          .child(`↻ resume ${n} ${n === 1 ? "agent" : "agents"}`)));
  }
}
