
local function setup()
  require('telescope').setup()
  require('telescope').load_extension('fzf')
end

return {
  setup = setup
}
