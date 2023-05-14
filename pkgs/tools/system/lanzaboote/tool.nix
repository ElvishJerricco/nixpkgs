{ systemd
, makeWrapper
, stdenv
, binutils-unwrapped
, sbsigntool
, rustPlatform
, fetchFromGitHub
, lib
}:
let
  uefiPkgs = import ../../../../. {
    inherit (stdenv.hostPlatform) systemd;
    crossSystem = {
      # linuxArch is wrong here, it will yield arm64 instead of aarch64.
      config = "${stdenv.hostPlatform.qemuArch}-windows";
      rustc.config = "${stdenv.hostPlatform.qemuArch}-unknown-uefi";
      libc = null;
      useLLVM = true;
    };
  };
in
rustPlatform.buildRustPackage
rec {
  pname = "lanzaboote_tool";
  version = "0.3.0";
  src = fetchFromGitHub {
    owner = "nix-community";
    repo = "lanzaboote";
    rev = "v${version}";
    hash = "sha256-Fb5TeRTdvUlo/5Yi2d+FC8a6KoRLk2h1VE0/peMhWPs=";
  };
  sourceRoot = "source/rust/tool";

  TEST_SYSTEMD = systemd;

  cargoLock = {
    lockFile = ./Cargo-tool.lock;
  };

  passthru.stub = uefiPkgs.lanzaboote-stub;

  nativeBuildInputs = [
    makeWrapper
  ];

  postInstall = ''
    # Clean PATH to only contain what we need to do objcopy. Also
    # tell lanzatool where to find our UEFI binaries.
    mv $out/bin/lzbt $out/bin/lzbt-unwrapped
    makeWrapper $out/bin/lzbt-unwrapped $out/bin/lzbt \
      --set PATH ${
        lib.makeBinPath [ binutils-unwrapped sbsigntool ]
      } \
      --set LANZABOOTE_STUB ${passthru.stub}/bin/lanzaboote_stub.efi
  '';

  nativeCheckInputs = [
    binutils-unwrapped
    sbsigntool
  ];

  meta = with lib; {
    description = "Lanzaboote UEFI tooling for SecureBoot enablement on NixOS systems";
    homepage = "https://github.com/nix-community/lanzaboote";
    license = licenses.mit;
  };
}
