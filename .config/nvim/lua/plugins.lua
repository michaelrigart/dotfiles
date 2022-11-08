
local function load()
  local packer = require('packer')
  packer.startup(function(use)
    use 'wbthomason/packer.nvim'

    use 'EdenEast/nightfox.nvim'
    use {
      'nvim-lualine/lualine.nvim',
        requires = {'kyazdani42/nvim-web-devicons', opt = true}
    }


    use {
    'kyazdani42/nvim-tree.lua',
    requires = {'kyazdani42/nvim-web-devicons', opt = true},
    config = function() require'nvim-tree'.setup {} end
    }

    use { 'ibhagwan/fzf-lua',
      requires = { 'vijaymarupudi/nvim-fzf', 'kyazdani42/nvim-web-devicons' } -- optional for icons
    }

    use 'vim-ruby/vim-ruby'
    use 'tpope/vim-rails'
    use 'tpope/vim-bundler'
    
    if packer_bootstrap then
      require('packer').sync()
    end
  end)
end


local function configure_colorschema()
  local nightfox = require('nightfox')
  nightfox.setup({
    transparent = false, -- Disable setting the background color
    terminal_colors = false, -- Configure the colors used when opening :terminal
    options = {
      dim_inactive = true, -- Non current window bg to alt color see `hl-NormalNC`
      styles = {
        comments = "italic", -- Style that is applied to comments: see `highlight-args` for options
        functions = "NONE", -- Style that is applied to functions: see `highlight-args` for options
        keywords = "NONE", -- Style that is applied to keywords: see `highlight-args` for options
        strings = "NONE", -- Style that is applied to strings: see `highlight-args` for options
        variables = "NONE", -- Style that is applied to variables: see `highlight-args` for options
      },
      inverse = {
        match_paren = false, -- Enable/Disable inverse highlighting for match parens
        visual = false, -- Enable/Disable inverse highlighting for visual selection
        search = false, -- Enable/Disable inverse highlights for search highlights
      },
    },
    palettes = {}, -- Override default colors
    groups = {} -- Override highlight groups
  })
  vim.cmd('colorscheme nightfox')
 -- vim.g.lightline = {'colorscheme': 'nightfox'}
end

local function configure()
  configure_colorschema()
	
    -- @plugin lualine
--  require('lualine').setup {
--      options = {
--          theme = 'auto',
--      },
--      extensions = {'quickfix', 'fzf', 'fugitive'},
--      sections = {
--  lualine_a = {
--    {
--      'buffers',
--      show_filename_only = true, -- shows shortened relative path when false
--      show_modified_status = true, -- shows indicator then buffer is modified
--      mode = 2, -- 0 shows buffer name
                -- 1 buffer index (bufnr)
                -- 2 shows buffer name + buffer index (bufnr)
--      max_length = vim.o.columns * 2 / 3, -- maximum width of buffers component
                                          -- can also be a function that returns value of max_length dynamicaly
 --     filetype_names = {
 --       TelescopePrompt = 'Telescope',
 --       dashboard = 'Dashboard',
 --       packer = 'Packer',
 --       fzf = 'FZF',
 --       alpha = 'Alpha'
 --     }, -- shows specific buffer name for that filetype ( { `filetype` = `buffer_name`, ... } )
 --     buffers_color = {
        -- Same values like general color option can be used here.
  --      active = 'lualine_{section}_normal', -- color for active buffer
  --      inactive = 'lualine_{section}_inactive', -- color for inactive buffer
  --    },
  --  }
 -- }
--}
--  }

end


--
-- Set up all the plugins.
--
local function setup()
  load()
  configure()
end

return {
  setup = setup,
}
