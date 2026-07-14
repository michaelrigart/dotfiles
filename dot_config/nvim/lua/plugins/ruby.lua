-- Ruby LSP wiring for the LazyVim `lang.ruby` extra.
--
-- Mason's shared ruby-lsp binary causes Ruby ABI mismatches against mise-managed
-- Rubies, so disable it and launch ruby-lsp under the project's mise environment.
-- ruby-lsp then builds its own `.ruby-lsp` composed bundle (project deps + RuboCop)
-- and relaunches itself against it — no need to add ruby-lsp to any Gemfile.
--
-- Prereq: `ruby-lsp` installed for the project's Ruby, e.g. from the repo:
--   mise x -- gem install ruby-lsp
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        ruby_lsp = {
          mason = false,
          cmd = { "mise", "x", "--", "ruby-lsp" },
        },
      },
    },
  },
}
