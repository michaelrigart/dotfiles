# Michael's setup

This folder is deployed by chezmoi from Michael's dotfiles repository (main checkout
`~/.local/share/chezmoi`, public). Herdr's `AGENTS.md` stays the reference for how the app
works; where a change goes is decided here and in the repository's own `AGENTS.md`, which has
the rest (previews, tests, the allowlist).

- **Never edit a managed file here,** this one included. They come from `dot_config/herdr-app/`
  in the repository (`keys.json`, `programs.json` and `claude-settings.json` from `.tmpl`
  templates), so a lasting note goes in `dot_config/herdr-app/AGENTS.local.md`. Change the source in a `wt` checkout of the repository, never in the main checkout; it
  deploys once Michael merges it and runs `chezmoi apply`, which overwrites an edit made here.
- **A new file or mod** goes in the source too, with its own `!` re-include in the
  repository's `.chezmoiignore`: this folder is an allowlist, and chezmoi silently drops
  anything not on it. The repository is public, so nothing private goes in these files.
- **`mods/michael-spaces` and `mods/michael-menu`** are clones of Herdr's `spaces` and
  `menu` mods: `bin/respaces` makes them again and applies `patches/` with `bin/patch-mod`.
  Never edit them or add them to the repository: change `patches/` or `bin/patch-mod` in the
  source. Once Michael has applied it, `respaces` must be run to rebuild the clones; the app
  runs it by itself only after a Herdr update.
- **`settings.json`** is a `create_` seed: chezmoi writes it only when it is missing, and the
  app owns it after that. To bring a live change back into the source, run
  `command chezmoi --source <wt checkout> add --create ~/.config/herdr-app/settings.json`.
- Everything else here (`view.json`, `shared.json`, `data/`, Herdr's shipped mods and
  layouts, `AGENTS.md`) is the app's own.
