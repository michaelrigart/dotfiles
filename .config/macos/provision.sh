#!/usr/bin/env zsh

RUBY_VERSION=2.7.1
PYTHON_VERSION=3.9.0
YARN_VERSION=latest
NODEJS_VERSION=12.19.0

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
  'coreutils'
  'freetds'               # Unix lib to connect to MSSQL
  'fzf'                   # A command-line fuzzy finder
  'git'                   # update system git with latest version
  'git-flow'              # Tool for gitflow branching model
  'gnupg'
  'htop'                  # htop is an interactive text-mode process viewer for Unix systems. It aims to be a better 'top'.
  'libpq'                 # programming interface for postgresql
  'neovim'                # Drop-in replacement for Vim
  'the_silver_searcher'   # A code-searching tool similar to ack, but faster ag command used in Vim / CLI
  'tmux'
  'tmuxinator-completion'
  'vcsh'                  # config manager based on Git
  'zsh'                   # Zsh is a shell designed for interactive use, although it is also a powerful scripting language.
  'zsh-completion'        # Additional completion definitions for Zsh.
)

echo '========== Installing CLI apps =========='
for app in "${cliApps[@]}"
do
  brew list $app > /dev/null

  local LAST_EXIT_CODE=$?
  if [[ $LAST_EXIT_CODE -ne 0 ]]; then
      brew install $app
  else
      brew upgrade $app
  fi
done

echo '========== Set default shell to zsh =========='
sudo /usr/bin/env zsh -c 'grep -qxF /usr/local/bin/zsh /etc/shells || echo /usr/local/bin/zsh >> /etc/shells'
chsh -s /usr/local/bin/zsh

echo '========== Tap fonts caskroom'
brew tap homebrew/cask-fonts
# endpoint security vpn
declare -a guiApps=(
  '1password'                # 1Password password manager
  'adobe-acrobat-reader'
  'alfred'
  'discord'
  'docker'                   # Containerize, but not all things
  'dropbox'                  # Some cloud storage
  'eul'
  'firefox'                  # Using firefox as default browser
  'font-fira-code-nerd-font'  # Currently using this patched font in vim. Includes icons
  'freemind'                 # Mindmapping tool
  'geekbench'
  'google-chrome'
  'iterm2'                   # Iterm2 is so much better than macOS Terminal
  'jetbrains-toolbox'        # Currently still using IntelliJ
  'kap'
  'keybase'                  # Security APP for end-to-end encryption
  'little-snitch'            # macOS firewall
  'micro-snitch'             # macOS mic & cam detection
  'microsoft-teams'
  'miro'
  'nordvpn'                  # secure connection with VPN
  'notion'
  'obs'
  'onlyoffice'
#  'pocket-casts'
  'postman'                  # Postman for API development
  'signal'                   # secure messing app
  'skype'                    # Still used a lot for conf-calls
  'slack'
#  'sony-ps4-remote-play'
  'spotify'
#  'viscosity'                # VPN client
  'yubico-yubikey-manager'
  'yubico-authenticator'
)


echo '========== Installing GUI apps =========='
for app in "${guiApps[@]}"
do
  brew install --cask $app
done

echo '========== Tap drivers caskroom =========='
brew tap homebrew/cask-drivers

declare -a drivers=(
  'focusrite-control'
)

echo '========== Install drivers =========='
for driver in "${drivers[@]}"
do
    brew install $driver
done

echo '========== Cleanup brew installation =========='
brew cleanup

# Need to login into some apps in order to install checkout sdots before continuing
# keybase / dropbox / 1password
while read "REPLY?Ready preparing for dotfile installation? Login Keybase, dropbox, 1password [y]es|[n]o: " && [[ $REPLY != 'y' ]]; do
  case $REPLY in
    q) exit 0;
  esac
done

echo '========== Installing dotfiles =========='
cd $HOME
if [ -d "${HOME}/.config/vcsh/repo.d/sdot.git" ]; then
  echo ' ---- sdot already installed'
else
  echo ' ---- install sdot'
  vcsh init sdot
  vcsh sdot remote add origin 'keybase://private/michaelrigart/dotfiles'
  vcsh sdot pull origin master
  vcsh sdot branch --set-upstream-to=origin/master master
  vcsh sdot pull
fi

if [ -d "${HOME}/.config/vcsh/repo.d/dot.git" ]; then
  echo ' ---- dot already installed'
else
  echo ' ---- install dot'
  vcsh init dot
  vcsh dot remote add origin 'git@github.com:michaelrigart/dotfiles.git'
  vcsh dot pull origin master
  vcsh dot branch --set-upstream-to=origin/master master
  vcsh dot pull
fi

echo '========== Installing oh-my-zsh =========='
if [ -d "${XDG_DATA_HOME}/oh-my-zsh" ]; then
  echo ' ---- oh-my-zsh already installed'
else
  echo ' ---- install oh-my-zsh'
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)"
fi

echo '========== Installing powerlevel10 theme =========='
if [ -d "${ZSH}/custom/themes/powerlevel10k" ]; then
  echo ' ---- update powerlevel10k theme'
  cd "${ZSH}/custom/themes/powerlevel10k"
  git pull
  cd $HOME
else
  echo ' ---- install powerlevel10k theme'
  git clone https://github.com/romkatv/powerlevel10k.git "${ZSH}/custom/themes/powerlevel10k"
fi

echo '========== Installing zsh-syntax-highlighting =========='
if [ -d "${ZSH}/custom/plugins/zsh-syntax-highlighting" ]; then
  echo '---- update zsh-syntax-highlighting'
  cd "${ZSH}/custom/plugins/zsh-syntax-highlighting"
  git pull
  cd $HOME
else
  echo '---- install zsh-syntax-highlighting plugin'
  git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "${ZSH}/custom/plugins/zsh-syntax-highlighting"
fi

echo '========== Resource zsh profile =========='
source $HOME/.zshrc

echo '========== Add ASDF Ruby plugin =========='
asdf plugin-add ruby

echo "========== Install Ruby $RUBY_VERSION =========="
asdf install ruby $RUBY_VERSION

echo "========== Set default ruby version to $RUBY_VERSION =========="
asdf global ruby $RUBY_VERSION

echo '========== Update RubyGems =========='
gem update --system

echo '========== Add ASDF Python plugin =========='
asdf plugin-add python

echo "========== Install Python $PYTHON_VERSION =========="
asdf install python $PYTHON_VERSION

echo "========== Set default python version to $PYTHON_VERSION =========="
asdf global python $PYTHON_VERSION

echo '========== Update Pip =========='
pip install --upgrade pip

echo '========== Add ASDF Yarn plugin =========='
asdf plugin-add yarn

echo "========== Install Yarn $YARN_VERSION =========="
asdf install yarn $YARN_VERSION

echo '========== Install ASDF NodeJS plugin =========='
asdf plugin-add nodejs https://github.com/asdf-vm/asdf-nodejs.git

echo '========== Install Node.js OpenPGP keys =========='
bash -c "${ASDF_DATA_DIR:=$HOME/.asdf}/plugins/nodejs/bin/import-release-team-keyring"

echo "========== Install Node.js $NODEJS_VERSION =========="
asdf install nodejs $NODEJS_VERSION

echo "========== Set default nodejs version to $NODEJS_VERSION =========="
asdf global nodejs $NODEJS_VERSION

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
