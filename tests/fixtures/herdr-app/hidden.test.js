// What waits while the window is hidden, run headless under jsc by tests/herdr-app.test.sh
// (./rows-stubs.js stands in for the app's modules): phases.js's look (the spaces pane's badges)
// and the usage mod's refresh. The app keeps a mod's timers running while its window is hidden,
// so each tick reads window()?.visible itself. Starting a look or a refresh is a cx.spawn, which
// the fake cx counts without running.
import { Phases } from "./phases.js";
import Usage from "./usage.js";
import { setWindow } from "./rows-stubs.js";

const check = (what, ok) => print(`  ${ok ? "PASS" : "FAIL"}: ${what}`);
const hidden = { visible: false };
const shown = { visible: true };

const fakeCx = () => {
  const cx = { spawned: 0, tick: null, notify() {}, spawn() { cx.spawned += 1; }, timer: { every(_ms, f) { cx.tick = f; } } };
  return cx;
};

// A Phases with nothing looked up yet; `at` stale or not.
const phases = (stale) => {
  const p = Object.create(Phases.prototype);
  Object.assign(p, { by: {}, forge: {}, asking: {}, watching: new Set(), forgeOf: {}, warned: new Set(), defaults: {}, dirty: false, seen: "[]", at: stale ? 0 : Date.now() });
  return p;
};

// --- phases.js: the badges -------------------------------------------------------------------
{
  const cx = fakeCx();
  setWindow(shown);
  phases(false).tick(cx);
  check("phases: a tick with nothing due looks nothing up", cx.spawned === 0);
  phases(true).tick(cx);
  check("phases: a tick with local state due looks it up", cx.spawned === 1);
}
{
  const cx = fakeCx();
  const p = phases(true);
  setWindow(hidden);
  p.tick(cx);
  p.dirty = true;
  p.tick(cx);
  check("phases: while the window is hidden a due look waits, a changed repository too", cx.spawned === 0);
  setWindow(shown);
  p.tick(cx);
  check("phases: the first tick after it shows again looks", cx.spawned === 1);
}
{
  const cx = fakeCx();
  const p = phases(false);
  setWindow(hidden);
  p.forced = true;
  p.tick(cx);
  check("phases: a refresh asked for while hidden waits", cx.spawned === 0 && p.forced === true);
  setWindow(shown);
  p.tick(cx);
  check("phases: ...and runs at the first tick after the window shows", cx.spawned === 1 && p.forced === false);
}
{
  const cx = fakeCx();
  setWindow(null);
  phases(true).tick(cx);
  check("phases: with no window at all (herdr-app check) a due look runs", cx.spawned === 1);
}

// --- the usage mod -----------------------------------------------------------------------------
{
  const cx = fakeCx();
  const u = new Usage();
  setWindow(shown);
  u.init({}, cx);
  check("usage: it refreshes once when it starts", cx.spawned === 1);
  cx.tick(cx);
  check("usage: a tick before the minute is up refreshes nothing", cx.spawned === 1);
  u.at -= 60000;
  setWindow(hidden);
  cx.tick(cx);
  check("usage: while the window is hidden a due refresh waits", cx.spawned === 1);
  setWindow(shown);
  cx.tick(cx);
  check("usage: the first tick after it shows again refreshes", cx.spawned === 2);
  u.at -= 60000;
  setWindow(null);
  cx.tick(cx);
  check("usage: with no window at all (herdr-app check) a due refresh runs", cx.spawned === 3);
}
{
  const cx = fakeCx();
  setWindow(hidden);
  new Usage().init({}, cx);
  check("usage: started while hidden, it waits for the window", cx.spawned === 0);
}
