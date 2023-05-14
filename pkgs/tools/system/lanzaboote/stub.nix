{ rustPlatform, fetchFromGitHub, stdenv, lib }:

rustPlatform.buildRustPackage {
  pname = "lanzaboote-stub";
  version = "0.3.0";

  src = fetchFromGitHub {
    owner = "nix-community";
    repo = "lanzaboote";
    rev = "v0.3.0";
    hash = "sha256-Fb5TeRTdvUlo/5Yi2d+FC8a6KoRLk2h1VE0/peMhWPs=";
  };

  sourceRoot = "source/rust/stub";

  cargoHash = "sha256-FlnheCgowYsEHcFMn6k8ESxDuggbO4tNdQlOjUIj7oE=";

  # `cc-wrapper`/our clang doesn't understand MSVC link opts (hack):
  RUSTFLAGS = "-Clinker=${stdenv.cc.bintools}/bin/${stdenv.cc.targetPrefix}ld.lld -Clinker-flavor=lld-link";
  NIX_ENFORCE_PURITY = "0";

  # TODO: limit supported platforms to UEFI
  meta.platforms = lib.platforms.all;
}
