-- provision.sh step 12b, after `Lazy! install`: a headless Neovim that quits aborts the installs
-- LazyVim starts in the background (Mason's tools, the treesitter parsers), so this waits for them.
-- Quits 0 when everything is installed, else 1 naming what is not.
require("lazy").load({ plugins = { "mason.nvim", "nvim-treesitter" } })
local tools = LazyVim.opts("mason.nvim").ensure_installed or {}
local parsers = LazyVim.opts("nvim-treesitter").ensure_installed or {}
local mr = require("mason-registry")
local TS = require("nvim-treesitter")
local TIMEOUT = 15 * 60 * 1000
local function pkg(tool)
  local ok, p = pcall(mr.get_package, tool)
  return ok and p or nil
end
local function missing_parsers()
  local have = {}
  for _, lang in ipairs(TS.get_installed()) do
    have[lang] = true
  end
  return vim.tbl_filter(function(lang) return not have[lang] end, parsers)
end

-- Starts only what LazyVim's own refresh callback did not (Mason refuses a second install).
-- Scheduled, because that callback runs after this one when the registry was stale. Mason
-- calls back on a failed refresh too.
local refreshed = false
mr.refresh(function()
  vim.schedule(function()
    for _, tool in ipairs(tools) do
      local p = pkg(tool)
      if p and not p:is_installed() and not p:is_installing() then
        p:install()
      end
    end
    refreshed = true
  end)
end)

-- nvim-treesitter waits at most 60 s for a parser LazyVim's install is already building, then
-- moves on, so rounds go on until two in a row install nothing.
local left, idle = missing_parsers(), 0
while #left > 0 and idle < 2 do
  pcall(function() TS.install(left):wait(TIMEOUT) end)
  local now = missing_parsers()
  idle = #now < #left and 0 or idle + 1
  left = now
end
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
for _, lang in ipairs(missing_parsers()) do
  missing[#missing + 1] = "parser " .. lang
end
if #missing == 0 then
  vim.cmd("qall!")
end
io.stderr:write("not installed: " .. table.concat(missing, ", ") .. "\n")
vim.cmd("cquit 1")
