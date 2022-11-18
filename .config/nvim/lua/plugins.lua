
--
-- Set up all the plugins.
--
local function setup()
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

    -- Autocompletion plugin
    use { 'hrsh7th/nvim-cmp', requires = { 'hrsh7th/cmp-nvim-lsp', 'hrsh7th/cmp-buffer', 'hrsh7th/cmp-path', 'L3MON4D3/LuaSnip', 'saadparwaiz1/cmp_luasnip', 'rafamadriz/friendly-snippets' } }
    require('plugins/cmp').setup()

    -- enable LSP
    use { 'neovim/nvim-lspconfig' }
    require('plugins/lsp-config').setup()

    use 'vim-ruby/vim-ruby'
    use 'tpope/vim-rails'
    use 'tpope/vim-bundler'

    if packer_bootstrap then
      require('packer').sync()
    end
  end)
end

return {
  setup = setup
}
