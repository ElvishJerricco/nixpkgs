{ lib, python3 }:

python3.pkgs.buildPythonApplication rec {
  pname = "lit";
  version = "15.0.1";

  src = python3.pkgs.fetchPypi {
    inherit pname version;
    sha256 = "84ae8245d4f4dcb4562d7b95b6fecd53a7b3562af1e348949ce8794969a3a9b6";
  };

  passthru = {
    python = python3;
  };

  # Non-standard test suite. Needs custom checkPhase.
  doCheck = false;

  meta = {
    description = "Portable tool for executing LLVM and Clang style test suites";
    homepage = "http://llvm.org/docs/CommandGuide/lit.html";
    license = lib.licenses.ncsa;
    maintainers = with lib.maintainers; [ dtzWill ];
  };
}
