
local function setup()
  -- Enable mouse support in all modes
  vim.opt.mouse = 'a'

  -- Show line numbers
  vim.opt.number = true

  -- Highlight the current line
  vim.opt.cursorline = true

  -- Convert tabs to spaces
  vim.opt.expandtab = true

  -- set term gui colors (most terminals support this)
  vim.opt.termguicolors = true

  -- the number of spaces inserted for each indentation
  vim.opt.shiftwidth = 2

  -- insert 2 spaces for a tab
  vim.opt.tabstop = 2

  -- make indenting smarter again
  vim.opt.smartindent = true
  -- show popup even when one option and do not select a match in the menu
  vim.opt.completeopt = { "menuone", "noselect" }

  -- faster completion
  vim.opt.updatetime = 300

  --
end

return {
  setup = setup
}
