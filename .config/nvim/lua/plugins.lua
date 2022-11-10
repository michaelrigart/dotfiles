
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
      'akinsho/bufferline.nvim', 
        requires = 'nvim-tree/nvim-web-devicons'
    }


    use { 'kyazdani42/nvim-tree.lua',
      requires = { 'kyazdani42/nvim-web-devicons', opt = true }
    }

    use { 'ibhagwan/fzf-lua',
      requires = { 'vijaymarupudi/nvim-fzf', 'kyazdani42/nvim-web-devicons' } -- optional for icons
    }

    use { 'gpanders/editorconfig.nvim' }

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
	
  require('lualine').setup()
  require('nvim-tree').setup()
  require('bufferline').setup({
    options = {
      offsets = {
        {
          filetype = "NvimTree",
          text = "File Explorer",
          highlight = "Directory",
          separator = true -- use a "true" to enable the default, or set your own character
        }
      }
    }
  })
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
