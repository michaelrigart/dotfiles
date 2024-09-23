#!/usr/bin/env zsh

RUBY_VERSION=3.3.5
PYTHON_VERSION=3.12.6

while read "REPLY?Ready preparing for dotfile installation? .ssh keys must be present! [y]es|[n]o: " && [[ $REPLY != 'y' ]]; do
  case $REPLY in
    q) exit 0;
  esac
done


if ! [ -x "$(command -v brew)" ]; then
  echo '========== Installing Homebrew =========='
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
  echo "========== Update Homebrew ========="
  brew update
fi

echo '========== Install needed software =========='
curl -o ~/Downloads/Brewfile https://raw.githubusercontent.com/michaelrigart/dotfiles/refs/heads/main/private_dot_config/homebrew/Brewfile
brew bundle install --file ~/Downloads/Brewfile
rm ~/Downloads/Brewfile

echo '========== Set default shell to zsh =========='
sudo /usr/bin/env zsh -c 'grep -qxF ${HOMEBREW_PREFIX}/bin/zsh /etc/shells || echo ${HOMEBREW_PREFIX}/bin/zsh >> /etc/shells'
chsh -s $HOMEBREW_PREFIX/bin/zsh

echo '========== Cleanup brew installation =========='
brew cleanup

# Need to login into some apps in order to install checkout sdots before continuing
# keybase / dropbox / 1password
while read "REPLY?Ready preparing for dotfile installation? Login 1password [y]es|[n]o: " && [[ $REPLY != 'y' ]]; do
  case $REPLY in
    q) exit 0;
  esac
done

echo '========== Installing dotfiles =========='
cd $HOME


if [ -d "${HOME}/.local/share/chezmoi" ]; then
  echo ' ---- dotfiles already installed'
else
  echo ' ---- install dotfiles'
  chezmoi init --apply git@github.com:michaelrigart/dotfiles.git
fi

echo '========== Installing oh-my-zsh =========='
if [ -d "${XDG_DATA_HOME}/oh-my-zsh" ]; then
  echo ' ---- oh-my-zsh already installed'
  omz update
else
  echo ' ---- install oh-my-zsh'
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)"
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

echo '========== Create cache directories =========='
mkdir -p "${XDG_CACHE_HOME}/irb"
