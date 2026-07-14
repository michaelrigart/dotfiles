-- Seamless Ctrl-h/j/k/l navigation between Neovim splits and Zellij panes.
-- Pairs with the vim-zellij-navigator plugin configured in ~/.config/zellij/config.kdl:
-- Zellij forwards Ctrl-hjkl to Neovim when a pane runs nvim; smart-splits moves the
-- split, or hands off to Zellij at the edge. Requires `zellij` on $PATH.
--
-- These maps override LazyVim's default <C-hjkl> window navigation. After install,
-- verify with `:verbose map <C-h>` — it should resolve to smart-splits, not LazyVim.
return {
  "mrjones2014/smart-splits.nvim",
  lazy = false,
  keys = {
    { "<C-h>", function() require("smart-splits").move_cursor_left() end, desc = "Move to left split/pane" },
    { "<C-j>", function() require("smart-splits").move_cursor_down() end, desc = "Move to below split/pane" },
    { "<C-k>", function() require("smart-splits").move_cursor_up() end, desc = "Move to above split/pane" },
    { "<C-l>", function() require("smart-splits").move_cursor_right() end, desc = "Move to right split/pane" },
  },
}
