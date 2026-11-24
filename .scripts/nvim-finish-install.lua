-- provision.sh step 12b, after `Lazy! install`: a headless Neovim that quits aborts the installs
-- LazyVim starts in the background (Mason's tools, the treesitter parsers), so this waits for them.
-- Quits 0 when everything is installed, else 1 naming what is not.
require("lazy").load({ plugins = { "mason.nvim", "nvim-treesitter" } })
local tools = LazyVim.opts("mason.nvim").ensure_installed or {}
local parsers = LazyVim.opts("nvim-treesitter").ensure_installed or {}
local mr = require("mason-registry")
local function pkg(tool)
  local ok, p = pcall(mr.get_package, tool)
  return ok and p or nil
end

-- Runs after LazyVim's own refresh callback, so it starts only what that one did not (Mason
-- refuses a second install of a package). Mason calls back on a failed refresh too.
local refreshed = false
mr.refresh(function()
  for _, tool in ipairs(tools) do
    local p = pkg(tool)
    if p and not p:is_installed() and not p:is_installing() then
      p:install()
    end
  end
  refreshed = true
end)

local TIMEOUT = 15 * 60 * 1000
pcall(function()
  require("nvim-treesitter").install(parsers):wait(TIMEOUT) -- waits for a parser LazyVim is building
end)
vim.wait(TIMEOUT, function()
  return refreshed and not vim.iter(tools):any(function(t)
    local p = pkg(t)
    return p and p:is_installing()
  end)
end, 500)

local missing = vim.iter(tools):filter(function(t)
  local p = pkg(t)
  return not (p and p:is_installed())
end):totable()
local have = {}
for _, lang in ipairs(require("nvim-treesitter").get_installed()) do
  have[lang] = true
end
for _, lang in ipairs(parsers) do
  if not have[lang] then
    missing[#missing + 1] = "parser " .. lang
  end
end
if #missing == 0 then
  vim.cmd("qall!")
end
io.stderr:write("not installed: " .. table.concat(missing, ", ") .. "\n")
vim.cmd("cquit 1")
