#!/usr/bin/env zsh
# Install by running /bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/michaelrigart/dotfiles/refs/heads/main/private_dot_config/private_macos/private_executable_provision.sh)"

RUBY_VERSION=3.4.4
PYTHON_VERSION=3.12.6

while read "REPLY?Ready preparing for dotfile installation? .ssh keys must be present! [y]es|[n]o: " && [[ $REPLY != 'y' ]]; do
  case $REPLY in
    q) exit 0;
  esac
done


if ! [ -x "$(command -v brew)" ]; then
  echo '========== Installing Homebrew =========='
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  (echo; echo 'eval "$(/opt/homebrew/bin/brew shellenv)"') >> /Users/michael/.zprofile
  eval "$(/opt/homebrew/bin/brew shellenv)"
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

echo '========== Install other dependencies =========='
gcloud components install gke-gcloud-auth-plugin

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

if [ -f "${HOME}/.zprofile" ]; then
  rm "${HOME}/.zprofile"
  source "${HOME}/.zshrc"
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

echo "========== Install Ruby $RUBY_VERSION =========="
mise use -g ruby@$RUBY_VERSION

echo '========== Update RubyGems =========='
gem update --system

echo "========== Install Python $PYTHON_VERSION =========="
mise use -g python@$PYTHON_VERSION

echo '========== Create cache directories =========='
mkdir -p "${XDG_CACHE_HOME}/irb"

echo '========== Cleanup =========='
if [ -f "${HOME}/.zprofile" ]; then
  rm "${HOME}/.zprofile"
  source "${HOME}/.zshrc"
fi

if [ -f "${HOME}/.zprofile.bak" ]; then
  rm "${HOME}/.zprofile.bak"
fi

if [ -f "${HOME}/.zshrc.pre-oh-my-zsh" ]; then
  source "${HOME}/.zshrc.pre-oh-my-zsh"
fi




rm .zshrc.pre-oh-my-zsh

