
local function load()
  local packer = require('packer')
  packer.startup(function(use)
    use { 'wbthomason/packer.nvim' }

    use { 'EdenEast/nightfox.nvim' }
    require('plugins/nightfox').setup()

    use { 'nvim-lualine/lualine.nvim', requires = {'kyazdani42/nvim-web-devicons' } }
    require('plugins/lualine').setup()

    use { 'akinsho/bufferline.nvim', requires = { 'nvim-tree/nvim-web-devicons' } }
    require('plugins/bufferline').setup()

    use { 'kyazdani42/nvim-tree.lua', requires = { 'kyazdani42/nvim-web-devicons' } }
    require('plugins/nvim-tree').setup()

    use { 'nvim-telescope/telescope.nvim', requires = { 'nvim-lua/plenary.nvim', 'kyazdani42/nvim-web-devicons', { 'nvim-telescope/telescope-fzf-native.nvim', run = 'make' } } }
    require('plugins/telescope').setup()

    use { 'nvim-treesitter/nvim-treesitter' }
    require('plugins/nvim-treesitter').setup()

    use { 'RRethy/nvim-treesitter-endwise', requires = { 'nvim-treesitter/nvim-treesitter' } }
    require('plugins/nvim-treesitter-endwise').setup()

    use { 'gpanders/editorconfig.nvim' }


    use { 'neovim/nvim-lspconfig' }     -- enable LSP
    use { 'hrsh7th/nvim-cmp' }          -- Autocompletion plugin
    use { 'hrsh7th/cmp-nvim-lsp' }      -- LSP source for nvim-cmp
    use { 'hrsh7th/cmp-buffer' }        -- Buffer source for nvim-cmp
    use { 'L3MON4D3/LuaSnip' }          -- nvim-cmp needs a snippet engine
    use { 'saadparwaiz1/cmp_luasnip' }  -- nvim-cmp needs a snippet engine (dep)

    use 'vim-ruby/vim-ruby'
    use 'tpope/vim-rails'
    use 'tpope/vim-bundler'

    if packer_bootstrap then
      require('packer').install()
      require('packer').sync()
    end
  end)
end


local function configure()
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

  local cmp = require 'cmp'

cmp.setup {
  snippet = {
    -- REQUIRED - you must specify a snippet engine
    expand = function(args)
      require('luasnip').lsp_expand(args.body) -- For `luasnip` users.
    end,
  },
  mapping = cmp.mapping.preset.insert({
    ['<C-Space>'] = cmp.mapping.complete(),
    ['<C-e>'] = cmp.mapping.close(),
    ['<CR>'] = cmp.mapping.confirm({ select = true }), -- Accept currently selected item. Set `select` to `false` to only confirm explicitly selected items.
  }),
  sources = cmp.config.sources({
    { name = 'nvim_lsp', group_index = 1 },
    { name = 'buffer', keyword_length = 4, group_index = 2 },
  }),
  formatting = {
    format = function(entry, vim_item)
      local menu_source = {
        nvim_lsp = '[LSP]',
        buffer = '[BUF]',
      }
      vim_item.menu = menu_source[entry.source.name]
      return vim_item
    end,
  },
}

-- Autocomplete searches
cmp.setup.cmdline('/', {
  mapping = cmp.mapping.preset.cmdline(),
  sources = {
    { name = 'buffer' },
  }
})

-- Wire up with LSP
local capabilities = require('cmp_nvim_lsp').default_capabilities(vim.lsp.protocol.make_client_capabilities())

  -- Use a loop to conveniently call 'setup' on multiple servers and
  -- map buffer local keybindings when the language server attaches
  local servers = { "solargraph" }
  for _, lsp in ipairs(servers) do
    nvim_lsp[lsp].setup {
      on_attach = on_attach,
      capabilities = capabilities,
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
