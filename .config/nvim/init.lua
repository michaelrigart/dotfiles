local fn = vim.fn
local install_path = fn.stdpath('data')..'/site/pack/packer/start/packer.nvim'
if fn.empty(fn.glob(install_path)) > 0 then
  packer_bootstrap = fn.system({'git', 'clone', '--depth', '1', 'https://github.com/wbthomason/packer.nvim', install_path})
end

vim.cmd [[ let mapleader = "," ]]

-- Toggle NvimTree
vim.cmd [[ nnoremap <leader>t :NvimTreeToggle<cr> ]]


-- -----------------------------------------------------------------------------
--  Buffers
-- -----------------------------------------------------------------------------

-- Open new buffer
vim.cmd [[ nnoremap <leader>N :enew<cr> ]]
-- Move to the next buffer
vim.cmd [[ nnoremap <leader>bn :bnext<CR> ]]
-- Move to the previous buffer
vim.cmd [[ nnoremap <leader>bp :bprevious<CR> ]]
-- Close the current buffer and move to the previous one.
-- This replicates the idea of closing a tab
vim.cmd [[ nnoremap <leader>w :bp <BAR> bd #<CR> ]]
-- Show all open buffers and their status
vim.cmd [[ nnoremap <leader>bl :ls<CR> ]]

require('plugins').setup()
require('settings').setup()
--require('options').setup()
--require('keybindings').setup()

vim.cmd [[ nnoremap <leader>ff <cmd>Telescope find_files<CR> ]]
vim.cmd [[ nnoremap <leader>fg <cmd>Telescope live_grep<CR> ]]
