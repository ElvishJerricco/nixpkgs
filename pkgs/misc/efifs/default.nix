{ stdenv, lib, which, buildPackages }:

let
  src = buildPackages.fetchgit {
    url = "https://github.com/pbatard/efifs.git";
    rev = "v1.3";
    sha256 = "117mlsbjn47vzz7b2xz0yr4kj0bmlkm93pl2abb5kgvk4jydm9g0";
    fetchSubmodules = true;
  };
in stdenv.mkDerivation {
  name = "efifs";
  inherit src;
  hardeningDisable = [ "all" ];
  nativeBuildInputs = [which];
  dontPatchELF = true;

  # Nixpkgs uses a different triple, but the compiler is identical.
  postPatch = ''
    sed -i Make.common -e 's|w64|pc|'
  '';

  # Fails to build if this is true.
  enableParallelBuilding = false;

  installPhase = ''
    mkdir -p $out
    find src -maxdepth 1 -name "*.efi" -exec mv -t $out {} +
  '';

  meta = {
    description = "EFI FileSystem drivers";
    homepage = https://efi.akeo.ie;
    license = stdenv.lib.licenses.gpl3;

    # This doesn't actually have anything to do with windows. It just
    # requires x86_64-w64-mingw32-gcc for some reason.
    platforms = lib.platforms.windows;
  };
}
