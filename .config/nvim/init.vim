if &compatible
  set nocompatible
endif
set runtimepath+=~/.cache/dein/repos/github.com/Shougo/dein.vim
set runtimepath+=/usr/local/opt/fzf

if dein#load_state(expand('~/.cache/dein'))
  call dein#begin(expand('~/.cache/dein'))

  call dein#add('Shougo/dein.vim')
  call dein#add('scrooloose/nerdtree')
  call dein#add('hzchirs/vim-material')
  call dein#add('ryanoasis/vim-devicons')
  call dein#add('vim-airline/vim-airline')

  call dein#add('Shougo/neosnippet.vim')
  call dein#add('Shougo/neosnippet-snippets')

  call dein#add('editorconfig/editorconfig-vim')

  call dein#add('qpkorr/vim-bufkill')

  call dein#add('tpope/vim-fugitive')
  call dein#add('tpope/vim-rhubarb')
  call dein#add('shumphrey/fugitive-gitlab.vim')

"  call dein#add('majutsushi/tagbar')

  call dein#add('airblade/vim-gitgutter')
  call dein#add('brookhong/ag.vim')

  call dein#add('vim-ruby/vim-ruby')
  call dein#add('tpope/vim-haml')
  call dein#add('sunaku/vim-ruby-minitest')
  call dein#add('tpope/vim-rails')
  call dein#add('tpope/vim-bundler')
  call dein#add('tpope/vim-endwise')
  call dein#add('tpope/vim-surround')
  call dein#add('jiangmiao/auto-pairs')

"  call dein#add('neoclide/coc.nvim', {'merged':0, 'rev': 'release'})

  call dein#end()
  call dein#save_state()
endif

filetype plugin indent on
syntax enable

" enable swapfiles but store them in a single directory
set swapfile
set dir=~/.cache/vim
set viminfo+=n~/.cache/vim/viminfo

" Appearance
set termguicolors
colorscheme vim-material
let g:airline_theme='material'
set guifont=Fura_Code_Retina_Nerd_Font_Complete:h12 " patched font for icons
set cursorline
set number
set colorcolumn=120
set mouse=nv

" Indentation and whitespace settings
set smartindent
set cindent
set autoindent
set shiftwidth=2
set softtabstop=2
set tabstop=2
set expandtab
set smarttab

" Gitgutter options
set updatetime=100 " faster update times so signs are show faster
set signcolumn=yes " show git changes next to numbers
let g:gitgutter_highlight_lines=0 " highlight changed lines

" Plugin options
set wildmenu
set completeopt=menu,longest
set completeopt -=preview

let g:WebDevIconsUnicodeDecorateFolderNodes = 1
let g:airline_powerline_fonts = 1
"let NERDTreeShowHidden=1 "(shift + i om te toggelen)
let NERDTreeIgnore = ['\.DS_Store']
let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tabline#buffer_nr_show = 1

" set viminfo path
let viminfopath=$XDG_CACHE_HOME."/vim/viminfo"
