#!/usr/bin/env zsh

if ! [ -x "$(command -v brew)" ]; then
  echo '========== Installing Homebrew =========='
  /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
else
  echo "========== Update Homebrew ========="
  brew update
fi

declare -a cliApps=(
  'ansible'               # Ansible is a radically simple IT automation platform that makes your applications and systems easier to deploy.
  'asdf'                  # Extendable version manager with support for Ruby, Node.js, Elixir, Erlang & more
  'codeclimate'           # Code Climate CLI
  'freetds'               # Unix lib to connect to MSSQL
  'git'                   # update system git with latest version
  'git-flow'              # Tool for gitflow branching model
  'htop'                  # htop is an interactive text-mode process viewer for Unix systems. It aims to be a better 'top'.
  'libpq'                 # programming interface for postgresql
  'neovim'                # Drop-in replacement for Vim
  'node'
  'terminal-notifier'     # command-line tool to send macOS user notifications
  'the_silver_searcher'   # A code-searching tool similar to ack, but faster ag command used in Vim / CLI
  'tmux'
  'tmuxinator-completion'
  'truncate'              # The truncate utility adjusts the length of	each regular file given	on the command-line
  'vcsh'                  # config manager based on Git
  'yarn'                  # Fast, reliable, and secure dependency management.
  'zsh'                   # Zsh is a shell designed for interactive use, although it is also a powerful scripting language.
  'zsh-completion'        # Additional completion definitions for Zsh.
)

echo '========== Installing CLI apps =========='
for app in "${cliApps[@]}"
do
  brew install $app
done

echo '========== Set default shell to zsh =========='
sudo /usr/bin/env zsh -c 'echo /usr/local/bin/zsh >> /etc/shells'
chsh -s /usr/local/bin/zsh

echo '========== Upgrading CLI apps =========='
brew upgrade

echo '========== Tap fonts caskroom'
brew tap homebrew/cask-fonts

declare -a guiApps=(
  '1password'                # 1Password password manager
  'docker-edge'              # Containerize, but not all things
  'dropbox'                  # Some cloud storage
  'firefox'                  # Using firefox as default browser
  'font-firacode-nerd-font'  # Currently using this patched font in vim. Includes icons
  'freemind'                 # Mindmapping tool
  'gpg-suite'                # Install GPG suite for handling GPG keys
  'iterm2'                   # Iterm2 is so much better than macOS Terminal
  'jetbrains-toolbox'        # Currently still using IntelliJ
  'keybase'                  # Security APP for end-to-end encryption
  'libreoffice'              # For some basic office stuff
  'little-snitch'            # macOS firewall
  'micro-snitch'             # macOS mic & cam detection
  'nordvpn'                  # secure connection with VPN
  'postman'                  # Postman for API development
  'signal'                   # secure messing app
  'skype'                    # Still used a lot for conf-calls
  'spideroakone'             # Secure cloud storage
  'viscosity'                # VPN client
)


echo '========== Installing GUI apps =========='
for app in "${guiApps[@]}"
do
  brew cask install $app
done

echo '========== Cleanup brew installation =========='
brew cleanup


# Need to login into some apps in order to install checkout sdots before continuing
# keybase / dropbox / 1password
while read "REPLY?Ready preparing for dotfile installation? [y]es|[n]o: " && [[ $REPLY != 'y' ]]; do
  case $REPLY in
    q) exit 0;
  esac
done

# Test is vcsh repos are present, else do not install them
echo '========== Installing dotfiles =========='
cd $HOME
if [ -d "${HOME}/.config/vcsh/repo.d/sdot.git" ]; then
  echo ' ---- sdot already installed'
else
  echo ' ---- install sdot'
  vcsh init sdot
  vcsh sdot remote add origin 'keybase://private/michaelrigart/dotfiles'
  vcsh sdot branch --set-upstream-to=origin/master master
  vcsh sdot pull
fi

if [ -d "${HOME}/.config/vcsh/repo.d/dot.git" ]; then
  echo ' ---- dot already installed'
else
  echo ' ---- install dot'
  vcsh init dot
  vcsh dot remote add origin 'git@github.com:michaelrigart/dotfiles.git'
  vcsh dot branch --set-upstream-to=origin/master master
  vcsh dot pull
fi

echo '========== Resource zsh profile =========='
source $HOME/.zshrc

echo '========== Add ASDF Ruby plugin =========='
asdf plugin-add ruby

echo '========== Install Ruby 2.6.2 =========='
asdf install ruby 2.6.2

echo '========== Install Ruby 2.6.3 =========='
asdf install ruby 2.6.3

echo '========== Set default ruby version to 2.6.3 =========='
asdf global ruby 2.6.3

echo '========== Update RubyGems =========='
gem update --system

echo '========== Add ASDF Python plugin =========='
asdf plugin-add python

echo '========== Install Python 3.7.3 =========='
asdf install python 3.7.3

echo '========== Set default python version to 3.7.3 =========='
asdf global python 3.7.3

echo '========== Update Pip =========='
pip install --upgrade pip

echo '========== Create cache directories =========='
mkdir -p "${XDG_CACHE_HOME}/irb"

echo "========== Install dein.vim plugin manager =========="
if [ -d "${XDG_CACHE_HOME}/dein" ]; then
  echo ' ---- dein.vim already installed'
else
  cd $HOME
  curl https://raw.githubusercontent.com/Shougo/dein.vim/master/bin/installer.sh > installer.sh
  sh ./installer.sh  "${XDG_CACHE_HOME}/dein"
  rm installer.sh
  echo ' ----- run :call dein#install() from within vim'
fi
