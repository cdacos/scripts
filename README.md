# scripts

Shared developer utility scripts.

## Scripts

### `dev-container.sh` (aka `dev!`)

Git worktree + Docker dev container launcher. Creates isolated dev environments where each branch gets its own worktree and container with a unique port.

```sh
dev! feature-auth         # Create/attach to branch
dev! kill feature-auth    # Tear down container + worktree
dev!                      # List all worktrees
dev! init node:20         # Generate skeleton Dockerfile.dev
```

### `check-tools.sh`

Checks for missing CLI tools and chezmoi configuration drift. Shows installation commands for your platform (brew/apt).

```sh
check-tools.sh
```

## Install

### With chezmoi

Add to your `.chezmoiexternal.toml`:

```toml
[".local/bin/dev-container.sh"]
    type = "file"
    url = "https://raw.githubusercontent.com/cdacos/scripts/main/dev-container.sh"
    executable = true
    refreshPeriod = "0"

[".local/bin/check-tools.sh"]
    type = "file"
    url = "https://raw.githubusercontent.com/cdacos/scripts/main/check-tools.sh"
    executable = true
    refreshPeriod = "0"
```

Then run `chezmoi apply`.

### Standalone

```sh
curl -fsSL https://raw.githubusercontent.com/cdacos/scripts/main/dev-container.sh -o ~/.local/bin/dev-container.sh
curl -fsSL https://raw.githubusercontent.com/cdacos/scripts/main/check-tools.sh -o ~/.local/bin/check-tools.sh
chmod +x ~/.local/bin/dev-container.sh ~/.local/bin/check-tools.sh
```
