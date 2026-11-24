#!/usr/bin/env bash
# Verifies .scripts/nvim-finish-install.lua, which provision.sh runs in a headless Neovim after
# `Lazy! install`: it waits for Mason's tools and the treesitter parsers, then exits 0 when all
# are installed, 1 naming what is not, and 2 (the caller's trailing `+cq 2`) when it errors.
# The real Neovim runs it with --clean, scratch XDG directories and stub modules for lazy,
# mason-registry and nvim-treesitter, so nothing is downloaded or built.
# Bug caught: a headless step that exited 0 with the tools and parsers aborted.
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SRC/.scripts/nvim-finish-install.lua"
pass=0; fail=0

if [ ! -f "$SCRIPT" ]; then
  echo "missing file under test: $SCRIPT"
  exit 2
fi
if ! command -v nvim >/dev/null 2>&1; then
  echo "INCONCLUSIVE: nvim is not on PATH"
  exit 2
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/nvim-finish-install.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT

ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

# TOOLS and PARSERS are "name:state" lists, in ensure_installed order.
# Tools: installed; fails (its install fails at once); installs (its install takes 300 ms);
# installing (already installing, done after 1 s); lazyvim (not installed, and LazyVim's own
# refresh callback installs it, running after this script's, as it does when the registry was
# stale). Parsers: installed; fails; installs; slow (LazyVim's build of it outlives the first
# round's wait, so only a second round finds it installed).
cat > "$T/stub.lua" <<'LUA'
local function parse(s)
  local names, state = {}, {}
  for name, st in (s or ""):gmatch("([%w_-]+):(%a+)") do
    names[#names + 1] = name
    state[name] = st
  end
  return names, state
end
local tool_names, tools = parse(vim.env.TOOLS)
local parser_names, parsers = parse(vim.env.PARSERS)

package.preload["lazy"] = function() return { load = function() end } end
if vim.env.NO_LAZYVIM == nil then
  _G.LazyVim = { opts = function(name)
    return { ensure_installed = name == "mason.nvim" and tool_names or parser_names }
  end }
end

local pkgs = {}
for _, name in ipairs(tool_names) do
  local p = { st = tools[name] }
  function p:is_installed() return self.st == "installed" end
  function p:is_installing() return self.st == "installing" end
  function p:install()
    assert(self.st ~= "installing", "Package is already installing.")
    if self.st == "fails" then return end
    self.st = "installing"
    vim.defer_fn(function() self.st = "installed" end, 300)
  end
  if p.st == "installing" then vim.defer_fn(function() p.st = "installed" end, 1000) end
  pkgs[name] = p
end
package.preload["mason-registry"] = function()
  return {
    get_package = function(name) return pkgs[name] or error("Cannot find package " .. name) end,
    refresh = function(cb)
      cb(true, {})
      for _, name in ipairs(tool_names) do
        if tools[name] == "lazyvim" then
          local ok, err = pcall(pkgs[name].install, pkgs[name])
          if not ok then io.stderr:write("LazyVim's callback: " .. tostring(err) .. "\n") end
        end
      end
    end,
  }
end

package.preload["nvim-treesitter"] = function()
  return {
    get_installed = function()
      local r = {}
      for _, lang in ipairs(parser_names) do
        if parsers[lang] == "installed" then r[#r + 1] = lang end
      end
      return r
    end,
    install = function(langs)
      for _, lang in ipairs(type(langs) == "table" and langs or { langs }) do
        if parsers[lang] == "installs" then parsers[lang] = "installed"
        elseif parsers[lang] == "slow" then parsers[lang] = "installs" end
      end
      return { wait = function() return true end }
    end,
  }
end
LUA

# finish <tools> <parsers> [env...]: run the script; sets RC and OUT (stdout and stderr).
finish() {
  local tools=$1 parsers=$2; shift 2
  OUT=$(cd "$T" && env TOOLS="$tools" PARSERS="$parsers" "$@" \
    XDG_CONFIG_HOME="$T/config" XDG_DATA_HOME="$T/data" XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache" \
    /usr/bin/timeout 60 nvim --clean --headless "+luafile $T/stub.lua" "+luafile $SCRIPT" "+cq 2" </dev/null 2>&1)
  RC=$?
}
rc_is() { [ "$RC" -eq "$1" ] && ok "$2" || bad "$2 (exit $RC, wanted $1: $OUT)"; }
has()   { case "$OUT" in *"$1"*) ok "$2" ;; *) bad "$2 (got: $OUT)" ;; esac; }
hasnt() { case "$OUT" in *"$1"*) bad "$2 (got: $OUT)" ;; *) ok "$2" ;; esac; }

echo "1. everything installed"
finish "stylua:installed shfmt:installed" "lua:installed ruby:installed"
rc_is 0 "exits 0"
hasnt "not installed" "and names nothing"

echo "2. what never installs is named"
finish "stylua:installed erb-lint:fails" "lua:installed ruby:fails"
rc_is 1 "a tool and a parser that fail: exits 1"
has "not installed: erb-lint, parser ruby" "and names both"

echo "3. it waits"
finish "shfmt:installing" "lua:installed"
rc_is 0 "a tool still installing when it starts: waits for it"
finish "shfmt:installs" "lua:installed"
rc_is 0 "a tool nothing has started: starts it and waits"
finish "stylua:installed" "lua:installs typescript:slow"
rc_is 0 "a parser LazyVim builds past nvim-treesitter's 60 s wait: another round waits for it"

echo "4. LazyVim's callback, when it runs after this one, finds nothing already installing"
finish "erb-lint:lazyvim" "lua:installed"
rc_is 0 "exits 0"
hasnt "already installing" "Mason is never asked to install a package twice"

echo "5. a script error"
finish "stylua:installed" "lua:installed" NO_LAZYVIM=1
rc_is 2 "falls through to the caller's +cq 2"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
