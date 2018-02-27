if &compatible
  set nocompatible
endif
set runtimepath+=~/.cache/dein/repos/github.com/Shougo/dein.vim
set runtimepath+=/usr/local/opt/fzf


if dein#load_state(expand('~/.cache/dein'))
  call dein#begin(expand('~/.cache/dein'))

  call dein#add('Shougo/dein.vim')
  call dein#add('Shougo/deoplete.nvim')
  call dein#add('scrooloose/nerdtree')
  call dein#add('hzchirs/vim-material')
  call dein#add('ryanoasis/vim-devicons')
  call dein#add('vim-airline/vim-airline')

  call dein#add('junegunn/fzf.vim')

  call dein#add('Shougo/neosnippet.vim')
  call dein#add('Shougo/neosnippet-snippets')

  call dein#add('editorconfig/editorconfig-vim')

  call dein#add('qpkorr/vim-bufkill')

  call dein#add('tpope/vim-fugitive')
  call dein#add('tpope/vim-rhubarb')
  call dein#add('shumphrey/fugitive-gitlab.vim')

  call dein#add('brookhong/ag.vim')

  call dein#add('uplus/deoplete-solargraph')
  call dein#add('fishbullet/deoplete-ruby')
  call dein#add('vim-ruby/vim-ruby')
  call dein#add('tpope/vim-haml')
  call dein#add('sunaku/vim-ruby-minitest')
  call dein#add('tpope/vim-rails')
  call dein#add('tpope/vim-bundler')
  call dein#add('tpope/vim-endwise')
  call dein#add('tpope/vim-surround')
  call dein#add('jiangmiao/auto-pairs')

  call dein#end()
  call dein#save_state()
endif

filetype plugin indent on
syntax enable

" Enable truecolor
set termguicolors

" Appearance
colorscheme vim-material

set encoding=utf-8
set guifont=Fura_Code_Retina_Nerd_Font_Complete:h12

set colorcolumn=120

let g:deoplete#enable_at_startup = 1
let g:WebDevIconsUnicodeDecorateFolderNodes = 1
let g:airline_powerline_fonts = 1
"let NERDTreeShowHidden=1 (shift + i om te toggelen)

let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tabline#buffer_nr_show = 1

set cursorline 

" deoplete tab for autocomplete
inoremap <expr> <Tab> pumvisible() ? "\<C-n>" : "\<Tab>"
inoremap <expr> <S-Tab> pumvisible() ? "\<C-p>" : "\<S-Tab>"

function BuildEditor ()
  execute ":NERDTree"
  :exe "normal \<S-i>"
  :exe "normal \<C-W>\<C-w>"
  set nu
endfunction	
command IDE call BuildEditor()
