{
  clippy,
  lib,
  rustPlatform,
  mkShell,
  rust-analyzer,
  rustfmt,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "nixos-systemd-unit-collector";
  version = "0.1.0";

  src = ./src;

  cargoLock.lockFile = ./src/Cargo.lock;

  nativeCheckInputs = [
    clippy
  ];

  preCheck = ''
    echo "Running clippy..."
    cargo clippy -- -Dwarnings
  '';

  passthru = {
    devShell = mkShell {
      inputsFrom = [ finalAttrs.finalPackage ];
      nativeBuildInputs = [
        rust-analyzer
        rustfmt
      ];
    };
  };

  meta = {
    description = "NixOS systemd unit collector";
    maintainers = [ lib.maintainers.teams.systemd ];
    license = lib.licenses.mit;
  };
})
