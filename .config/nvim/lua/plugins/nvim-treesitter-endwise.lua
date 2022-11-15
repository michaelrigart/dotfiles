
local function setup()
  require('nvim-treesitter.configs').setup {
    endwise = {
      enable = true
    }
  }
end

return {
  setup = setup
}
