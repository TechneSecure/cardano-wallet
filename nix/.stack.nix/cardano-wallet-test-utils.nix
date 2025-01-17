{ system, compiler, flags, pkgs, hsPkgs, pkgconfPkgs, ... }:
  {
    flags = { development = false; };
    package = {
      specVersion = "1.10";
      identifier = {
        name = "cardano-wallet-test-utils";
        version = "2019.6.24";
        };
      license = "MIT";
      copyright = "2019 IOHK";
      maintainer = "operations@iohk.io";
      author = "IOHK Engineering Team";
      homepage = "https://github.com/input-output-hk/cardano-wallet";
      url = "";
      synopsis = "Shared utilities for writing unit and property tests.";
      description = "Shared utilities for writing unit and property tests.";
      buildType = "Simple";
      };
    components = {
      "library" = {
        depends = [ (hsPkgs.base) (hsPkgs.QuickCheck) (hsPkgs.time) ];
        };
      };
    } // rec { src = (pkgs.lib).mkDefault ../.././lib/test-utils; }