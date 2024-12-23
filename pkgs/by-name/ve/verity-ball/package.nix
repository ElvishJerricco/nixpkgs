{
  lib,
  rustPlatform,
}:

let
  cargo = lib.importTOML ./src/Cargo.toml;
in
rustPlatform.buildRustPackage {
  pname = cargo.package.name;
  version = cargo.package.version;

  src = ./src;

  cargoLock.lockFile = ./src/Cargo.lock;

  meta = {
    description = "Convert a tarball into a meta-only tarball with fs-verity digests.";
    maintainers = [ lib.maintainers.elvishjerricco ];
  };
}
