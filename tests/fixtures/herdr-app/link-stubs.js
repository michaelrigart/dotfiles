// A headless stand-in for the "herdr" module that mods/nav/link.js and mods/nav/nvim.js import,
// so the link handler runs under jsc. A test sets `world` (spaces, panes, what `hc get` and the
// socket lookup answer, and how Neovim answers) and reads back `calls`.

export const world = { spaces: [], panes: [], foreground: {}, servers: {}, nvim: () => ({ code: 0, stdout: "1\n", stderr: "" }) };
export const calls = [];

export const spaces = () => world.spaces;
export const panes = () => world.panes;
export const run = (name, args) => { calls.push(["run", name, args]); return null; };

export async function hc(args) {
  calls.push(["hc", args]);
  const fg = args[0] === "get" ? world.foreground[args[1]] : undefined;
  return fg === undefined ? { code: 1, stdout: "", stderr: "no such terminal" } : { code: 0, stdout: JSON.stringify({ foreground: fg }), stderr: "" };
}

export async function exec(command, args, options) {
  calls.push(["exec", command, args, options]);
  if (command === "sh") {
    const server = world.servers[args[args.length - 1]];
    if (server === "reject") throw new Error("timed out");
    return server ? { code: 0, stdout: server, stderr: "" } : { code: 1, stdout: "", stderr: "" };
  }
  if (command === "nvim") return world.nvim(args);
  throw new Error(`exec: unexpected ${command}`);
}
