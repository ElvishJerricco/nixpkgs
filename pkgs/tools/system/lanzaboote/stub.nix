{ rustPlatform, stdenv, lib, fetchFromGitHub }:

rustPlatform.buildRustPackage
rec {
  pname = "lanzaboote_stub";
  version = "0.3.0";
  src = fetchFromGitHub {
    owner = "nix-community";
    repo = "lanzaboote";
    rev = "v${version}";
    hash = "sha256-Fb5TeRTdvUlo/5Yi2d+FC8a6KoRLk2h1VE0/peMhWPs=";
  };

  sourceRoot = "source/rust/stub";

  cargoLock = {
    lockFile = ./Cargo-stub.lock;
  };

  # Necessary because our `cc-wrapper` doesn't understand MSVC link options.
  RUSTFLAGS = "-Clinker=${stdenv.cc.bintools}/bin/${stdenv.cc.targetPrefix}ld.lld -Clinker-flavor=lld-link";
  # Necessary because otherwise we will get (useless) hardening options in front of
  # -flavor link which will break the whole command-line processing for the ld.lld linker.
  hardeningDisable = [ "all" ];

  meta = with lib; {
    description = "Lanzaboote UEFI stub for SecureBoot enablement on NixOS systems";
    homepage = "https://github.com/nix-community/lanzaboote";
    license = licenses.mit;
    platforms = [ "x86_64-windows" "aarch64-windows" "i686-windows" ];
  };
}
