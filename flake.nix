{
  description = "tasksd-client.nvim — Neovim client for tasksd";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "tasksd-client.nvim";

          packages = with pkgs; [
            coreutils
            curl
            gnutar
            just
            lua-language-server
            neovim
            rustup
            selene
            stylua
          ];
          shellHook = ''
            export MINI_NVIM="${pkgs.vimPlugins.mini-nvim}"
            # stderr, so that `nix develop --command <cmd>` can be read from.
            echo "tasksd-client.nvim devshell — run 'just' to list recipes" >&2
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
