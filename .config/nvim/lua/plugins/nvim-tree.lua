
local function setup()
  require('nvim-tree').setup({
    filters = {
      custom = { '.DS_Store' }
    }
  })
end

return {
  setup = setup
}
