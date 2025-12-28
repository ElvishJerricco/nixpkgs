{
  lib,
  python3Packages,
  python3,
  mkShell,
  util-linux,
  systemd,
  bootspec,
  nix,
  distroName ? "NixOS",
}:

python3Packages.buildPythonApplication {
  pname = "systemd-boot-builder";
  version = lib.trivial.release;
  src = ./src;
  pyproject = true;

  build-system = with python3Packages; [
    setuptools
  ];

  propagatedBuildInputs = [
    (lib.getBin util-linux)
    (lib.getBin systemd)
    (lib.getBin bootspec)
    (lib.getBin nix)
    (python3Packages.pydantic)
  ];

  makeWrapperArgs = [ "--set NIXOS_DISTRO_NAME ${distroName}" ];

  nativeCheckInputs = with python3Packages; [
    mypy
    ruff
  ];

  # Optional: Disable default checks if you only want mypy
  doCheck = true; # Keep enabled to run checkPhase

  checkPhase = ''
    runHook preCheck
    mypy systemd_boot_builder --strict
    ruff check systemd_boot_builder
    ruff format --check --diff systemd_boot_builder
    runHook postCheck
  '';

  passthru = {
    devShell = mkShell {
      packages = [
        (python3.withPackages (
          ps: with ps; [
            mypy
            ruff
          ]
        ))
      ];
    };
  };

  meta = {
    mainProgram = "systemd-boot-builder";
  };
}
