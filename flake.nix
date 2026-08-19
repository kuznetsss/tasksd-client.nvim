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
            just
            stylua
            selene
            lua-language-server
            neovim
            rustup
          ];
          shellHook = ''
            export MINI_NVIM="${pkgs.vimPlugins.mini-nvim}"
            echo "tasksd-client.nvim devshell — run 'just' to list recipes"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
