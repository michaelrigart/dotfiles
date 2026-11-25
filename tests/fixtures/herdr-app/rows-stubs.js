// Headless stand-ins for what patches/phases.js, patches/rows.js and the usage mod import
// ("gpui-kit", "gpui-base" and "herdr"), so their logic runs under jsc. A builder records what it was told:
// `kids` (child, children), `calls` ([method, args] for every other method) and `handlers`
// (on_*); `when(cond, fn)` applies fn when cond holds. Tests read that structure back.

class Node {
  constructor(tag, args) {
    this.tag = tag;
    this.args = args;
    this.kids = [];
    this.calls = [];
    this.handlers = {};
  }
}

function builder(tag, args = []) {
  const node = new Node(tag, args);
  const proxy = new Proxy(node, {
    get(target, prop) {
      if (prop in target) return target[prop];
      return (...a) => {
        if (prop === "child") target.kids.push(a[0]);
        else if (prop === "children") target.kids.push(...a[0]);
        else if (prop === "when") { if (a[0]) a[1](proxy); }
        else {
          target.calls.push([prop, a]);
          if (prop.startsWith("on_")) target.handlers[prop] = a[a.length - 1];
        }
        return proxy;
      };
    },
  });
  return proxy;
}

export const div = () => builder("div");
export const h_flex = () => builder("h_flex");
export const svg = (path) => builder("svg", [path]);

export const spaces = () => [];
export const panes = () => [];
export const run = () => {};
export const exec = async () => ({ code: 1, stdout: "", stderr: "" });
export const home = () => "/home";
export const appHome = () => "/app";
export const notify = () => {};
export const nextCommand = () => new Promise(() => {});
export const watchFolder = () => new Promise(() => {});
export const theme = () => new Proxy({}, { get: (_, k) => String(k) });
export class View {}

// The app's window as a test sets it; null is no window at all, as in `herdr-app check`.
let shownWindow = { visible: true };
export const window = () => shownWindow;
export const setWindow = (w) => { shownWindow = w; };
