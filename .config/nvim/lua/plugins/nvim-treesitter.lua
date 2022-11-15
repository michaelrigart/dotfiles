
local function setup()
  require('nvim-treesitter.configs').setup({
    ensure_installed = { 'lua', 'ruby', 'comment' },
    highlight = { enable = true },
    indent = { enable = true },
  })
end

return {
  setup = setup
}
