{
  lib,
  python3Packages,
  python3,
  mkShell,
}:

python3Packages.buildPythonApplication {
  pname = "limine-install";
  version = lib.trivial.release;
  src = ./src;
  pyproject = true;

  build-system = with python3Packages; [
    setuptools
  ];

  propagatedBuildInputs = [
    (python3Packages.psutil)
  ];

  nativeCheckInputs = with python3Packages; [
    # mypy
    ruff
  ];

  # Optional: Disable default checks if you only want mypy
  doCheck = true; # Keep enabled to run checkPhase

  checkPhase = ''
    runHook preCheck
    # TODO: Fix
    # mypy limine_install --strict
    ruff check limine_install
    ruff format --check --diff limine_install
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
    mainProgram = "limine-install";
  };
}
