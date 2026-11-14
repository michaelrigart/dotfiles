// Keep michael-menu and michael-spaces in step with the app. The app updates itself almost
// daily and a clone is never updated, so after an update bin/respaces must make both again.
// This runs it once at start when the app's version is not the one the last successful run
// recorded, and says so when an update has changed a line bin/patch-mod matches: the clones
// are then plain copies of Herdr's mods (no phase badges, no worktree items) and nothing
// else shows it. Draws nothing.
//
// The first start has no record: the clones on disk were built on this version, so it is
// recorded and nothing runs. A failed run records nothing, so the next start tries again.
// bin/respaces replaces michael-menu and michael-spaces only, never this mod.

import { View, div } from "gpui-kit";
import { exec, readTextFile, writeTextFile, machines, updates, appHome, shared, setShared, notify } from "herdr";

const KEY = "respaces.version"; // the Herdr version bin/respaces last finished on
const POLL = 1500; // how often it looks whether this computer's layout has loaded
const RUN_MS = 600000; // the most exec allows: it clones twice and checks both
const SHOWN = 8000; // a success is news for a moment
// A failure must outlast a glance. herdr.d.ts documents no "until dismissed" for notify, so
// this is the longest timeout the app documents anywhere; a click dismisses it sooner.
const STAYS = 600000;

// Module scope is shared by every copy of this version, so a second init (a layout switch
// back, another copy) finds the run already started.
let started = false;

const lastLine = (text) => text.split("\n").map((l) => l.trim()).filter(Boolean).pop() ?? "";

// Replaces the file: writeTextFile only overwrites what it was told it is looking at.
async function writeLog(path, text) {
  let current = null;
  try { current = await readTextFile(path); } catch {}
  await writeTextFile(path, text, current);
}

export default class RespacesGuard extends View {
  init(_props, cx) {
    if (started) return;
    started = true;
    cx.spawn(async (cx) => {
      // Not before this computer's layout has loaded, as in mods/resume: respaces needs the
      // app's window, and right after a start `updates()` and the layout are still settling.
      while (machines().find((m) => m.name === null)?.layout !== "ready") {
        await new Promise((done) => cx.timer.after(POLL, () => done()));
      }
      await this.check();
    });
  }

  async check() {
    const version = updates()?.app?.version;
    if (!version) return;
    const recorded = shared(KEY);
    if (!recorded) return setShared(KEY, version);
    if (recorded === version) return;

    const log = `${appHome()}/respaces.log`;
    let r;
    try {
      r = await exec(`${appHome()}/bin/respaces`, [], { timeout: RUN_MS });
    } catch (e) {
      // It did not start, or was cut off at the timeout (a half-done run can leave a clone
      // aside): the same as a failure, with the reason in place of its output.
      r = { code: -1, stdout: "", stderr: `respaces did not finish: ${e?.message ?? e}\n` };
    }
    try {
      await writeLog(log, `exit ${r.code}\n--- stdout ---\n${r.stdout}\n--- stderr ---\n${r.stderr}\n`);
    } catch {}

    if (r.code === 0) {
      setShared(KEY, version);
      return notify({ title: `Herdr ${version}: michael-spaces and michael-menu rebuilt`, level: "info", timeout: SHOWN });
    }
    // patch-mod's and respaces' own messages go to stderr; what the failed step printed last
    // says which part it was.
    const why = lastLine(r.stderr) || lastLine(r.stdout) || `exit ${r.code}`;
    // Only a patch-mod edit that no longer matches leaves the plain Herdr mods behind.
    const plain = /edit \d+ matches \d+ times/.test(why)
      ? " The space menu and/or sidebar are Herdr's plain versions until bin/patch-mod is updated; ask Claude to do it."
      : "";
    notify({
      title: `Herdr ${version}: respaces failed`,
      body: `${why}${plain} Log: ${log}`,
      level: "warning",
      timeout: STAYS,
    });
  }

  render() {
    return div();
  }
}
