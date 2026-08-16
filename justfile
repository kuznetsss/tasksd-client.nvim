set shell := ["bash", "-euo", "pipefail", "-c"]

# Lua sources that stylua/selene operate on.
srcs := "lua plugin tests"
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

# tests/minimal_init.lua reads MINI_NVIM, so fail here with a fixable message
# rather than inside Neovim. Leading underscore keeps it out of `just --list`.
_devshell:
    @test -n "${MINI_NVIM:-}" \
      || { echo "MINI_NVIM is unset — enter the devshell (direnv allow / nix develop)"; exit 1; }

# Run the test suite with mini.test
test *ARGS: _devshell
    nvim --headless -u tests/minimal_init.lua -c 'lua MiniTest.run()' {{ ARGS }}

# Run a single test file, e.g. `just test-file tests/test_health.lua`
test-file FILE: _devshell
    nvim --headless -u tests/minimal_init.lua -c 'lua MiniTest.run_file("{{ FILE }}")'

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
