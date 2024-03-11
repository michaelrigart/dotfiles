
local function setup()
  require('tokyonight').setup({
    style = 'night'
  })
  vim.cmd('colorscheme tokyonight')
end

return {
  setup = setup
}
