{ system ? builtins.currentSystem
, crossSystem ? null
, config ? {}
# Import IOHK common nix lib
, iohkLib ? import ./nix/iohk-common.nix { inherit system crossSystem config; }
# Use nixpkgs pin from iohkLib
, pkgs ? iohkLib.pkgs
}:

with import ./nix/util.nix { inherit pkgs; };

let
  haskell = iohkLib.nix-tools.haskell { inherit pkgs; };
  src = iohkLib.cleanSourceHaskell ./.;

  inherit (iohkLib.rust-packages.pkgs) jormungandr;
  cardano-http-bridge = iohkLib.rust-packages.pkgs.cardano-http-bridge.overrideAttrs (oldAttrs: {
    version = "0.0.3";
    src = pkgs.fetchFromGitHub {
      owner = "KtorZ";
      repo = "cardano-http-bridge";
      fetchSubmodules = true;
      rev = "a0e05390bee29d90daeec958fdce97e08c437143";
      sha256 = "1ix9b0pp50397g46h9k8axyrh8395a5l7zixsqrsyq90jwkbafa3";
    };
    cargoSha256 = "1phiffgcs70rsv1y0ac6lciq384g2f014mn15pjvd02l09nx7k49";
  });
  cardano-sl-node = import ./nix/cardano-sl-node.nix { inherit pkgs; };

  haskellPackages = import ./nix/default.nix {
    inherit pkgs haskell src;
    inherit cardano-http-bridge cardano-sl-node jormungandr;
    inherit (iohkLib.nix-tools) iohk-extras iohk-module;
  };

in {
  inherit pkgs iohkLib src haskellPackages;
  inherit cardano-http-bridge cardano-sl-node jormungandr;
  inherit (haskellPackages.cardano-wallet.identifier) version;

  cardano-wallet = haskellPackages.cardano-wallet.components.exes.cardano-wallet;
  tests = collectComponents "tests" isCardanoWallet haskellPackages;
  benchmarks = collectComponents "benchmarks" isCardanoWallet haskellPackages;

  shell = haskellPackages.shellFor {
    name = "cardano-wallet-shell";
    packages = ps: with ps; [
      cardano-wallet
      cardano-wallet-cli
      cardano-wallet-core
      cardano-wallet-http-bridge
      bech32
      text-class
    ];
    buildInputs =
      with pkgs.haskellPackages; [ cabal-install hlint stylish-haskell weeder ghcid ]
      ++ [ cardano-http-bridge jormungandr cardano-sl-node pkgs.pkgconfig pkgs.sqlite-interactive ];
  };
}
