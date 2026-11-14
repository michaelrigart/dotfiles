# Sourced by tests/herdr-app.test.sh and tests/herdr-app-xreview.test.sh; $SRC is the repository.
#
# herdr_app_source <root>: a scratch chezmoi source at <root>/src holding what the Herdr app
#   tree is deployed from: .chezmoiignore (the allowlist) and dot_config/herdr-app.
# herdr_app_chezmoi <root> <args...>: chezmoi on that source with <root>/home as the destination
#   and HOME. Its config, state and cache are in <root>/aux, beside home and never above it
#   (chezmoi refuses to write a file that sits in an ancestor of the destination).
# herdr_app_render <root>: the source applied, so the tree is at <root>/home/.config/herdr-app,
#   modes and templates as `chezmoi apply` leaves them. Nonzero with chezmoi's stderr on failure.
herdr_app_source() {
  mkdir -p $1/src $1/home $1/aux || return
  : > $1/aux/empty.toml
  cp $SRC/.chezmoiignore $1/src/.chezmoiignore || return
  mkdir -p $1/src/dot_config || return
  cp -R $SRC/dot_config/herdr-app $1/src/dot_config/herdr-app
}
herdr_app_chezmoi() {
  local root=$1; shift
  HOME=$root/home command chezmoi --config $root/aux/empty.toml --source $root/src \
    --destination $root/home --persistent-state $root/aux/state.db --cache $root/aux/cache "$@"
}
herdr_app_render() {
  herdr_app_source $1 && herdr_app_chezmoi $1 apply --force
}
