{
  description = "kohaku-contracts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,

      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
        unstable = nixpkgs-unstable.legacyPackages.${system};

        aderynTarget = {
          x86_64-linux = "x86_64-unknown-linux-gnu";
          aarch64-linux = "aarch64-unknown-linux-gnu";
          x86_64-darwin = "x86_64-apple-darwin";
          aarch64-darwin = "aarch64-apple-darwin";
        }.${system};

        aderynHash = {
          x86_64-unknown-linux-gnu = "ffd6ca658962e211a3ac821c646f69c8e14bf1b1001cbfe091bcd4535a691e46";
          aarch64-unknown-linux-gnu = "961070bf5ee4ed0f82f67a261c616e1525ec1b036bae60cdaec94d087eb5e405";
          x86_64-apple-darwin = "c2ef361c6b2e24c20d478e6cb30cc427090f29c3501adb7190cb514623ce6d8d";
          aarch64-apple-darwin = "624c6652bb9478b38ddc255c27819cd5c6cb0448f5deb72036cc9cf5a27d4aac";
        }.${aderynTarget};

        aderyn = pkgs.stdenv.mkDerivation {
          pname = "aderyn";
          version = "0.6.8";
          src = pkgs.fetchurl {
            url = "https://github.com/cyfrin/aderyn/releases/download/aderyn-v0.6.8/aderyn-${aderynTarget}.tar.xz";
            sha256 = aderynHash;
          };
          sourceRoot = "aderyn-${aderynTarget}";
          nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.autoPatchelfHook
            pkgs.patchelf
          ];
          buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.stdenv.cc.cc.lib
          ];
          installPhase = ''
            install -Dm755 aderyn $out/bin/aderyn
          '';
        };

      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            # JS / WASM
            pkgs.bun
            pkgs.nodejs_22

            # Solidity
            unstable.foundry
            aderyn

            pkgs.just
            pkgs.sops
          ];
        };
      }
    );
}
