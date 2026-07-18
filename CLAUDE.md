# Context for Claude Code

> **Note:** This file is for AI context only. For human-readable documentation, see [README.md](README.md).

## Repository Purpose

macOS dotfiles managed with chezmoi, featuring XDG compliance, 1Password secret integration, and automated provisioning.

**Owner:** Michaël Rigart
**Platform:** macOS (Apple Silicon primary)
**Management:** chezmoi 2.40.0+
**Secrets:** 1Password CLI integration

---

## Critical Rules

### Security
- ❌ **NEVER commit secrets, tokens, passwords, or API keys**
- ✅ All secrets MUST use 1Password templates: `{{ onepasswordRead "op://..." }}`
- ✅ SSH keys are templates in `private_dot_ssh/`
- ✅ Always verify with `git diff` before committing sensitive files

### File Management
- ✅ Only add tools to Brewfile if actively used
- ✅ Scripts in `.scripts/` are ad-hoc helpers, NOT `run_once_*` scripts
- ✅ Keep README.md maintainable by linking to source files, not duplicating lists
- ❌ Do NOT add "nice to have" packages - only what's actually used

### Permissions
- Scripts (`.scripts/*.sh`): `755` — non-secret helpers; Git only stores the exec bit
  (mode `100755`), so a fresh clone produces `755`, not `700`. Do not rely on `700` here.
- SSH directory: `700`, private keys: `600`, public keys: `644`
- Sensitive configs: `600`
- Regular dotfiles: `644`

---

## Architecture Decisions

### Why XDG Compliance?
- Keeps `$HOME` clean
- Standard followed by modern tools
- Easier to backup/manage configs in `~/.config/`
- See: `dot_config/zsh/zshenv` for XDG variable setup

### Why 1Password Integration?
- Centralized secret management
- Secrets never touch disk unencrypted
- Easy rotation without updating dotfiles
- Templates render secrets at apply-time only

### Why Standalone Scripts vs run_once_?
- `provision.sh` and `configure.sh` are designed for ad-hoc execution
- They modify system settings and require user interaction
- Better for debugging and intentional re-runs
- `run_once_*` pattern only suitable for truly idempotent, safe operations

---

## File Structure Quick Reference

```
~/.local/share/chezmoi/
├── .backgrounds/              # [IGNORED] Wallpapers, copied by configure.sh
├── .scripts/                  # [IGNORED] Ad-hoc scripts
│   ├── provision.sh          # Full bootstrap (rarely re-run)
│   ├── configure.sh          # macOS settings (safe to re-run)
│   ├── reconcile-agents.sh   # Claude/Codex marketplaces + plugins (idempotent)
│   └── test-reconcile-agents.sh  # mocked test for reconcile-agents.sh
├── dot_config/               # → ~/.config/
│   ├── bundler/config.tmpl   # ⚠️  Contains 1Password secrets
│   ├── chezmoi/              # Chezmoi configuration
│   ├── git/                  # Git config, aliases, templates
│   ├── homebrew/Brewfile     # Package definitions
│   ├── zsh/                  # Shell: zshenv, config, aliases
│   └── ...                   # Other app configs
├── private_dot_ssh/          # ⚠️  SSH key templates from 1Password
├── .chezmoiignore           # Excludes from chezmoi apply
├── .chezmoiversion          # Minimum version: 2.40.0
├── .gitignore               # Protects against committing secrets
├── README.md                # [IGNORED] Human documentation
└── CLAUDE.md                # [IGNORED] This file
```

**Legend:**
- `[IGNORED]` = In `.chezmoiignore`, won't be applied to `$HOME`
- `⚠️` = Contains secrets via 1Password templates

---

## Common Operations

### Adding a Secret
```bash
# 1. Store in 1Password first
# 2. Create template:
cat > dot_config/app/config.tmpl <<'EOF'
api_key: {{ onepasswordRead "op://Private/Item/field" }}
EOF

# 3. Test template rendering:
chezmoi cat ~/.config/app/config

# 4. Apply:
chezmoi apply
```

### Adding a Package
```bash
# Only if actively using the tool
chezmoi edit ~/.config/homebrew/Brewfile
# Add: brew "package-name"
chezmoi apply
brew bundle install --file ~/.config/homebrew/Brewfile
```

### Checking for Security Issues
```bash
cd ~/.local/share/chezmoi

# Check for hardcoded secrets
grep -r "password\|secret\|token\|api[_-]key" \
  --include="*.toml" --include="*.yaml" \
  --include="*.sh" --include="*.conf" . \
  | grep -v "1Password\|onepassword"

# Verify what's staged
git diff --cached

# Check SSH key templates are not actual keys
grep -L "onepassword" private_dot_ssh/private_*.tmpl
```

---

## Template Syntax Reference

### 1Password Document (SSH keys)
```go
{{ onepasswordRead "op://Private/michael/private key?ssh-format=openssh" }}
```

### 1Password Field (tokens)
```go
{{ onepasswordRead "op://Private/GitHub Personal Access Token/token" }}
```

### Conditional based on OS
```go
{{ if eq .chezmoi.os "darwin" }}
# macOS specific
{{ end }}
```

### Available Data Variables
From `dot_config/chezmoi/chezmoi.toml.tmpl`:
- `{{ .name }}` - "Michaël Rigart"
- `{{ .email }}` - "michael@netronix.be"
- `{{ .hostname }}` - Computer name
- `{{ .is_darwin }}` - true on macOS
- `{{ .is_linux }}` - true on Linux
- `{{ .is_arm }}` - true on Apple Silicon

---

## Known Files with Secrets

### SSH Keys (All templated)
- `private_dot_ssh/private_michael.tmpl`
- `private_dot_ssh/private_borg.tmpl`
- `private_dot_ssh/private_borg-*.tmpl`
- `private_dot_ssh/private_viumore_rsa.tmpl`

### API Tokens (All templated)
- `dot_config/bundler/config.tmpl` - GitHub/GitLab tokens

### NOT Tracked
- `~/.docker/config.json` - Registry auth
- `~/.config/gh/hosts.yml` - GitHub auth (tracked, but no secrets stored)
- `.env` files - Excluded by `.gitignore`

---

## Troubleshooting

### "1Password CLI couldn't connect"
```bash
# Ensure 1Password app is running and CLI integration enabled
# Settings → Developer → Command Line Interface
eval $(op signin)
```

### Template won't render
```bash
# Test template syntax
chezmoi cat <target-path>

# Dry run to see what would change
chezmoi apply --dry-run --verbose
```

### Script permissions wrong
```bash
# Scripts should be executable (Git stores only the exec bit → 755 on clone)
chmod 755 ~/.local/share/chezmoi/.scripts/*.sh
git add --chmod=+x .scripts/*.sh
```

---

## When to Update This File

Update `CLAUDE.md` when:
- ✅ Architecture decisions change (e.g., switch from standalone to `run_once_*`)
- ✅ New secret storage patterns are established
- ✅ Security rules are added/modified
- ✅ File structure significantly changes

Do NOT update for:
- ❌ Package additions/removals (that's in Brewfile)
- ❌ User-facing documentation (that's in README.md)
- ❌ Individual config changes (self-documenting)

---

## Questions Claude Should Ask

Before making changes, Claude Code should verify:

1. **Adding secrets?** → "Is this secret templated from 1Password?"
2. **Adding packages?** → "Do you actively use this tool?"
3. **Tracking new files?** → "Does this contain any sensitive data?"
4. **Changing scripts?** → "Should this remain ad-hoc or become automated?"
5. **Modifying permissions?** → "Are these the correct security permissions?"

---

## Cross-Reference

**For human documentation:** See [README.md](README.md)
- Installation instructions
- Daily usage commands
- Feature overview
- License and contributing

**For package lists:** See source files directly
- Homebrew: [dot_config/homebrew/Brewfile](dot_config/homebrew/Brewfile)
- Mise tools: [dot_config/mise/config.toml](dot_config/mise/config.toml)
- Zsh plugins: [dot_config/zsh/config](dot_config/zsh/config)

**For security audit:** See `.gitignore` and `.chezmoiignore`
- What's excluded from git
- What's excluded from chezmoi apply
