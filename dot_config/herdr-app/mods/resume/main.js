// Bring agent sessions back after a terminal is lost. herdr-core gives a lost terminal a shell
// in its last folder and never runs its command again, so this remembers, per terminal, the
// command that resumes the exact session there, and the root process (`hc get` .pid) it ran
// under. A terminal back at a bare shell under a different root process was lost: it is
// resumed once that shell has settled, unless the session runs anywhere else (bin/session-running)
// or another terminal already takes it. The core itself restarting is no loss: it keeps every
// terminal, with the same root process. One back at a shell under the same process had its agent
// quit on purpose: that only gets the button in the status bar (or "resume.all" from keys.json).
// One under the same process with some other program in front (neither a shell nor an agent)
// is marked quit too, without the button: a quit that the next program hid from every scan.
// What is decided lives in decide.js.
//
// No agent hooks. The session id comes from what each agent already publishes:
//   Claude Code  ~/.claude/sessions/<pid>.json, its own registry of running sessions
//   Codex        the terminal title, which carries the session id
// and the flags from the running process, so a read-only Codex comes back read-only.

import { View, div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { panes, machines, hc, exec, readTextFile, home, appHome, shared, setShared, theme, notify, nextCommand } from "herdr";
import { PATIENCE, classify, reserve, claim } from "./decide.js";

const TICK = 1500; // how often it looks whether any pane changed (no process is run)
const EVERY = 10000; // how often it asks the core anyway
const SHELLS = ["zsh", "bash", "fish", "sh", "dash", "ksh"];
const KEY = "resume.sessions"; // terminal address -> { app, id, cwd, cmd, fresh, pid?, quit?, sent? }
const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;
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

// Whether a session runs anywhere now (bin/session-running): exit 1 alone says it does not.
// Any other answer, or no run at all, counts as running, and says so once per run.
let warnedRunning = false;
async function running({ app, id }) {
  try {
    const code = (await exec(`${appHome()}/bin/session-running`, [app, id], { timeout: 10000 })).code;
    if (code === 0) return true;
    if (code === 1) return false;
  } catch {}
  if (!warnedRunning) {
    warnedRunning = true;
    notify({ title: "Cannot tell whether agent sessions run elsewhere", body: "bin/session-running did not answer: those sessions are not resumed.", level: "warning" });
  }
  return true;
}

// id -> whether it runs, for the distinct sessions of these records.
async function answers(recs) {
  const byId = new Map(recs.map((r) => [r.id, r]));
  const out = new Map();
  await Promise.all([...byId].map(async ([id, rec]) => out.set(id, await running(rec))));
  return out;
}

// The sessions that count as running elsewhere: an id nobody answered for is one of them.
const elsewhere = (recs, said) => new Set(recs.filter((r) => said.get(r.id) !== false).map((r) => r.id));

// Records of terminals that are gone, dropped from `saved` once this computer's layout has
// loaded: right after a start there are no panes yet, and that must not read as "every
// terminal is gone". True when it dropped any.
function forget(saved) {
  if (machines().find((m) => m.name === null)?.layout !== "ready") return false;
  const live = new Set(panes().filter((p) => p.terminal && !p.terminal.includes("/")).map((p) => p.terminal));
  let changed = false;
  for (const address of Object.keys(saved)) {
    if (!live.has(address)) { delete saved[address]; changed = true; }
  }
  return changed;
}

const heldToast = (n) => notify({ title: `${n} not resumed: already running elsewhere`, level: "warning" });

export default class Resume extends View {
  init(_props, cx) {
    this.firstSeen = {}; // lost-path terminal address -> { pid, at }: when its new shell was first seen
    this.seen = []; // what the last scan saw in each asked terminal
    this.button = []; // remembered terminals back at a shell that were not lost
    this.resuming = 0; // sends in flight
    this.sending = new Set(); // their addresses: a launch under way is not for the button
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
        // This computer's terminals only: a remote address carries its machine's name.
        const local = panes().filter((p) => p.terminal && !p.terminal.includes("/"));
        // The pane's own `program` is no guide here: it keeps an agent's last report after
        // the agent has quit, and has none for a Claude that never reported. What runs in
        // the terminal now is asked of the core, for every pane that could matter, at once.
        const known = shared(KEY) ?? {};
        const asked = local.filter((p) => !(p.program?.shell && !known[p.terminal]));
        const seen = await Promise.all(asked.map(async (p) => {
          const t = await get(p.terminal);
          const pid = Number.isInteger(t?.pid) ? t.pid : null;
          const name = t?.foreground?.name ?? "";
          if (SHELLS.includes(name.replace(/^-/, ""))) return { address: p.terminal, pid, shell: true, other: false, now: null };
          // Another program in front (a failed `hc get` has no name, so it is not one).
          const other = name !== "" && name !== "claude" && name !== "codex";
          return { address: p.terminal, pid, shell: false, other, now: await record(t) };
        }));
        // Which sessions run elsewhere is asked for the terminals a first look calls lost.
        const first = { ...known };
        forget(first);
        const lost0 = classify(first, seen, this.firstSeen, Date.now()).lost;
        const said = await answers(lost0.map((a) => first[a]));
        // From here to setShared nothing is awaited: the records are read fresh, decided on
        // and claimed in one go, so no other scan or click can take the same session between.
        const saved = { ...(shared(KEY) ?? {}) };
        let changed = forget(saved);
        const now = Date.now();
        const r = classify(saved, seen, this.firstSeen, now);
        const { go, held } = reserve(r.lost, r.saved, seen, elsewhere(r.lost.map((a) => r.saved[a]), said));
        const gaveUp = held.filter((a) => now - r.firstSeen[a].at >= PATIENCE);
        // Claimed for this terminal's new shell before sending: a resume that fails leaves
        // the button, never a loop of retries.
        const next = claim(claim(r.saved, go, { firstSeen: r.firstSeen, sent: true }), gaveUp, { firstSeen: r.firstSeen });
        changed = changed || r.changed || go.length > 0 || gaveUp.length > 0;
        if (changed) setShared(KEY, next);
        this.firstSeen = r.firstSeen;
        this.seen = seen;
        for (const a of go) this.sending.add(a);
        this.button = [...r.button, ...gaveUp].filter((a) => !this.sending.has(a));
        this.again = r.again; // a new shell is not settled yet: look again on the next tick
        if (gaveUp.length) heldToast(gaveUp.length);
        if (go.length) cx.spawn((cx) => this.send(cx, go, next, true));
      } finally {
        this.busy = false;
        cx.notify();
      }
    });
  }

  // The button, or "resume.all": the terminals at a shell that were not lost.
  restore(cx) {
    if (!this.button.length) return notify({ title: "No agent sessions to resume", timeout: 2000 });
    if (this.clicked) return;
    this.clicked = true;
    this.resuming++;
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        const addresses = this.button.filter((a) => !this.sending.has(a) && shared(KEY)?.[a]);
        const said = await answers(addresses.map((a) => shared(KEY)[a]));
        // As in scan: read fresh, decide and claim without awaiting in between.
        const saved = { ...(shared(KEY) ?? {}) };
        const live = addresses.filter((a) => saved[a] && !this.sending.has(a));
        const { go, held } = reserve(live, saved, this.seen, elsewhere(live.map((a) => saved[a]), said));
        const next = claim(saved, go, { sent: true });
        for (const a of go) this.sending.add(a);
        if (go.length) setShared(KEY, next);
        this.button = this.button.filter((a) => !go.includes(a));
        if (held.length) heldToast(held.length);
        if (go.length) await this.send(cx, go, next, false);
      } finally {
        this.clicked = false;
        this.resuming--;
        cx.notify();
      }
    });
  }

  // Sends each terminal its resume command; `auto`: they were lost, not clicked.
  async send(cx, addresses, saved, auto) {
    this.resuming++;
    cx.notify();
    // All at once: each send waits on its own terminal, not on the one before it.
    const sent = await Promise.all(addresses.map(async (address) => {
      const rec = saved[address];
      try {
        return (await hc(["send", address, `cd ${quote(rec.cwd)} && ${(await written(rec)) ? rec.cmd : rec.fresh}`])).code === 0;
      } catch {
        return false;
      } finally {
        this.sending.delete(address);
      }
    }));
    const failed = sent.filter((ok) => !ok).length;
    const what = `${addresses.length - failed}${failed ? ` of ${addresses.length}` : ""} agent ${addresses.length === 1 ? "session" : "sessions"}`;
    if (failed) notify({ title: `Resumed ${what}`, level: "warning" });
    else if (auto) notify({ title: `Resumed ${what} after a restart`, timeout: 3000 });
    this.resuming--;
    cx.notify();
  }

  render() {
    const t = theme();
    const n = this.button.length;
    return h_flex().size_full().px(10).items_center().justify_end()
      .bg(t.chrome).border_t(1).border_color(t.border).text_size(11.8)
      .when(this.resuming > 0, (el) => el.child(h_flex().gap(6).px(6).text_color(t.muted)
        .child(div().frames(["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"], 90)).child("resuming…")))
      .when(n > 0 && !this.resuming, (el) => el.child(
        div().id("resume-all").px(6).rounded(4).text_color(t.accent).cursor_pointer()
          .hover((s) => s.bg(t.hover))
          .on_click((_e, cx) => this.restore(cx))
          .child(`↻ resume ${n} ${n === 1 ? "agent" : "agents"}`)));
  }
}
