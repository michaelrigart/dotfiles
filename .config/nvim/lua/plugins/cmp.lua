
local function setup()
  local cmp = require 'cmp'
  local luasnip = require "luasnip"

  require("luasnip.loaders.from_vscode").lazy_load()

  luasnip.filetype_extend("ruby", { "rails" })

  cmp.setup {
    snippet = {
      -- REQUIRED - you must specify a snippet engine
      expand = function(args)
        luasnip.lsp_expand(args.body) -- For `luasnip` users.
      end,
    },
    mapping = cmp.mapping.preset.insert({
      ['<C-Space>'] = cmp.mapping.complete(),
      ['<C-e>'] = cmp.mapping.close(),
      ['<CR>'] = cmp.mapping.confirm({ select = true }), -- Accept currently selected item. Set `select` to `false` to only confirm explicitly selected items.
    }),
    sources = cmp.config.sources({
      { name = 'nvim_lsp' },
      { name = 'luasnip' },
      { name = 'buffer' },
    }),
    formatting = {
      format = function(entry, vim_item)
        local menu_source = {
          nvim_lsp = '[LSP]',
          luasnip = '[SNIP]',
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
end

return {
  setup = setup
}


