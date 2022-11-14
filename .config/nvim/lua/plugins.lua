
local function load()
  local packer = require('packer')
  packer.startup(function(use)
    use 'wbthomason/packer.nvim'

    use 'EdenEast/nightfox.nvim'
    use {
      'nvim-lualine/lualine.nvim',
        requires = {'kyazdani42/nvim-web-devicons' }
    }

    use {
      'akinsho/bufferline.nvim',
        requires = 'nvim-tree/nvim-web-devicons'
    }


    use { 'kyazdani42/nvim-tree.lua',
      requires = { 'kyazdani42/nvim-web-devicons' }
    }

    use { 'nvim-telescope/telescope.nvim',
      requires = { 'nvim-lua/plenary.nvim', 'kyazdani42/nvim-web-devicons', {'nvim-telescope/telescope-fzf-native.nvim', run = 'make' } }
    }

    use { 'gpanders/editorconfig.nvim' }


    use 'neovim/nvim-lspconfig'

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

  require('telescope').setup()
  require('telescope').load_extension('fzf')

  require('lspconfig').solargraph.setup({})
local nvim_lsp = require('lspconfig')

-- Use an on_attach function to only map the following keys
-- after the language server attaches to the current buffer
local on_attach = function(client, bufnr)
  local function buf_set_keymap(...) vim.api.nvim_buf_set_keymap(bufnr, ...) end
  local function buf_set_option(...) vim.api.nvim_buf_set_option(bufnr, ...) end

  --Enable completion triggered by <c-x><c-o>
  buf_set_option('omnifunc', 'v:lua.vim.lsp.omnifunc')

  -- Mappings.
  local opts = { noremap=true, silent=true }

  -- See `:help vim.lsp.*` for documentation on any of the below functions
  buf_set_keymap('n', 'gD', '<Cmd>lua vim.lsp.buf.declaration()<CR>', opts)
  buf_set_keymap('n', 'gd', '<Cmd>lua vim.lsp.buf.definition()<CR>', opts)
  buf_set_keymap('n', 'K', '<Cmd>lua vim.lsp.buf.hover()<CR>', opts)
  buf_set_keymap('n', 'gi', '<cmd>lua vim.lsp.buf.implementation()<CR>', opts)
  buf_set_keymap('n', '<C-k>', '<cmd>lua vim.lsp.buf.signature_help()<CR>', opts)
  buf_set_keymap('n', '<space>wa', '<cmd>lua vim.lsp.buf.add_workspace_folder()<CR>', opts)
  buf_set_keymap('n', '<space>wr', '<cmd>lua vim.lsp.buf.remove_workspace_folder()<CR>', opts)
  buf_set_keymap('n', '<space>wl', '<cmd>lua print(vim.inspect(vim.lsp.buf.list_workspace_folders()))<CR>', opts)
  buf_set_keymap('n', '<space>D', '<cmd>lua vim.lsp.buf.type_definition()<CR>', opts)
  buf_set_keymap('n', '<space>rn', '<cmd>lua vim.lsp.buf.rename()<CR>', opts)
  buf_set_keymap('n', '<space>ca', '<cmd>lua vim.lsp.buf.code_action()<CR>', opts)
  buf_set_keymap('n', 'gr', '<cmd>lua vim.lsp.buf.references()<CR>', opts)
  buf_set_keymap('n', '<space>e', '<cmd>lua vim.lsp.diagnostic.show_line_diagnostics()<CR>', opts)
  buf_set_keymap('n', '[d', '<cmd>lua vim.lsp.diagnostic.goto_prev()<CR>', opts)
  buf_set_keymap('n', ']d', '<cmd>lua vim.lsp.diagnostic.goto_next()<CR>', opts)
  buf_set_keymap('n', '<space>q', '<cmd>lua vim.lsp.diagnostic.set_loclist()<CR>', opts)
  buf_set_keymap("n", "<space>f", "<cmd>lua vim.lsp.buf.formatting()<CR>", opts)

end

-- Use a loop to conveniently call 'setup' on multiple servers and
-- map buffer local keybindings when the language server attaches
local servers = { "solargraph" }
for _, lsp in ipairs(servers) do
  nvim_lsp[lsp].setup {
    on_attach = on_attach,
    flags = {
      debounce_text_changes = 150,
    }
}
end

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
