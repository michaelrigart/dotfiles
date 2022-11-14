local function load()
  --- Helpers
  local cmd = vim.cmd      -- To execute Vim commands e.g. cmd('pwd')
  local g = vim.opt_global -- Acces to global options (must exist)
  local G = vim.g          -- Access to global options (can be non-existant, e.g. a plugin's settings)
  local o = vim.opt_local  -- Access to local options (must exist)

  -- Enable mouse support in all modes
  g.mouse = 'a'

  -- Show line numbers
  o.number = true

  -- TODO
  g.ru = true

end

local function setup()
  load()
end

return {
  setup = setup,
}
