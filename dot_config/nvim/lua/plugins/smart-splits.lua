-- Seamless Ctrl-h/j/k/l navigation between Neovim splits and Herdr panes, via
-- smart-splits.nvim's bundled Herdr plugin and native backend. It forwards the
-- chord into Neovim, moves an editor split when possible, and hands off to the
-- surrounding pane at the edge.
--
-- These maps override LazyVim's default <C-hjkl> window navigation. After install,
-- verify with `:verbose map <C-h>` — it should resolve to smart-splits, not LazyVim.
return {
  "mrjones2014/smart-splits.nvim",
  -- v3 moved the bundled Herdr plugin (herdr-plugin.toml, which provisioning links) out of
  -- this repository; v2.1.1-final is the last release that ships it.
  tag = "v2.1.1-final",
  lazy = false,
  keys = {
    { "<C-h>", function() require("smart-splits").move_cursor_left() end, desc = "Move to left split/pane" },
    { "<C-j>", function() require("smart-splits").move_cursor_down() end, desc = "Move to below split/pane" },
    { "<C-k>", function() require("smart-splits").move_cursor_up() end, desc = "Move to above split/pane" },
    { "<C-l>", function() require("smart-splits").move_cursor_right() end, desc = "Move to right split/pane" },
  },
}
