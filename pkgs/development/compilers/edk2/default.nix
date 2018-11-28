{ stdenv, fetchgit, fetchpatch, libuuid, python2, iasl }:

let
  pythonEnv = python2.withPackages(ps: [ps.tkinter]);

targetArch = if stdenv.isi686 then
  "IA32"
else if stdenv.isx86_64 then
  "X64"
else if stdenv.isAarch64 then
  "AARCH64"
else
  throw "Unsupported architecture";

edk2 = stdenv.mkDerivation {
  name = "edk2-2018-11";

  src = fetchgit {
    url = "https://github.com/tianocore/edk2";
    rev = "edk2-stable201811";
    sha256 = "0jf0apfms830gszql8gm29lmn3p3acdhnafbjjfwggw4invns5fz";
    fetchSubmodules = true;
  };

  # patches = [
  #   (fetchpatch {
  #     name = "short-circuit-the-transfer-of-an-empty-S3_CONTEXT.patch";
  #     url = "https://github.com/tianocore/edk2/commit/9e2a8e928995c3b1bb664b73fd59785055c6b5f6.diff";
  #     sha256 = "0x24npijhgpjpsn3n74wayf8qcbaj97vi4z2iyf4almavqq8qaz4";
  #   })
  # ];

  buildInputs = [ libuuid pythonEnv ];

  makeFlags = "-C BaseTools";

  hardeningDisable = [ "format" "fortify" ];

  installPhase = ''
    mkdir -vp $out
    mv -v BaseTools $out
    mv -v EdkCompatibilityPkg $out
    mv -v edksetup.sh $out
  '';

  enableParallelBuilding = true;

  meta = {
    description = "Intel EFI development kit";
    homepage = https://sourceforge.net/projects/edk2/;
    license = stdenv.lib.licenses.bsd2;
    branch = "UDK2017";
    platforms = ["x86_64-linux" "i686-linux" "aarch64-linux"];
  };

  passthru = {
    setup = projectDscPath: attrs: {
      buildInputs = [ pythonEnv ] ++
        stdenv.lib.optionals (attrs ? buildInputs) attrs.buildInputs;

      configurePhase = ''
        mkdir -v Conf

        cp ${edk2}/BaseTools/Conf/target.template Conf/target.txt
        sed -i Conf/target.txt \
          -e 's|Nt32Pkg/Nt32Pkg.dsc|${projectDscPath}|' \
          -e 's|MYTOOLS|GCC49|' \
          -e 's|IA32|${targetArch}|' \
          -e 's|DEBUG|RELEASE|'\

        cp ${edk2}/BaseTools/Conf/tools_def.template Conf/tools_def.txt
        sed -i Conf/tools_def.txt \
          -e 's|DEFINE GCC48_IA32_PREFIX       = /usr/bin/|DEFINE GCC48_IA32_PREFIX       = ""|' \
          -e 's|DEFINE GCC48_X64_PREFIX        = /usr/bin/|DEFINE GCC48_X64_PREFIX        = ""|' \
          -e 's|DEFINE UNIX_IASL_BIN           = /usr/bin/iasl|DEFINE UNIX_IASL_BIN           = ${iasl}/bin/iasl|'

        export WORKSPACE="$PWD"
        export EFI_SOURCE="$PWD/EdkCompatibilityPkg"
        ln -sv ${edk2}/BaseTools BaseTools
        ln -sv ${edk2}/EdkCompatibilityPkg EdkCompatibilityPkg
        . ${edk2}/edksetup.sh BaseTools
      '';

      buildPhase = "
        build
      ";

      installPhase = "mv -v Build/*/* $out";
    } // (removeAttrs attrs [ "buildInputs" ] );
  };
};

in

edk2
