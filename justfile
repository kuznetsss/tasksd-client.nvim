set shell := ["bash", "-euo", "pipefail", "-c"]

# Lua sources that stylua/selene operate on.
srcs := "lua plugin"
# Scratch dir for lua-language-server logs / reports (gitignored).
build := ".build"

# List available recipes
default:
    @just --list --unsorted

# Format Lua sources in place
fmt:
    stylua {{ srcs }}

# Verify formatting without writing (CI-friendly)
fmt-check:
    stylua --check {{ srcs }}

# Lint with selene
lint:
    selene {{ srcs }}

# Type-check with lua-language-server against the Neovim runtime
typecheck:
    @mkdir -p {{ build }}/luals
    VIMRUNTIME="$(nvim --clean --headless +'lua io.stderr:write(vim.env.VIMRUNTIME)' +q 2>&1 1>/dev/null)" \
      lua-language-server \
        --check . \
        --checklevel=Warning \
        --configpath=.luarc.json \
        --logpath={{ build }}/luals

# Run every static check
check: fmt-check lint typecheck

# Format, then run every static check
fix: fmt check

# Remove generated artifacts
clean:
    rm -rf {{ build }}

# Open Neovim with this plugin on the runtimepath and nothing else
nvim *ARGS:
    nvim --clean --cmd 'set runtimepath^={{ justfile_directory() }}' {{ ARGS }}
