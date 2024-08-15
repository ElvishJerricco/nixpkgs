{
  lib,
  fetchFromGitHub,
  nixosTests,
  dotnetCorePackages,
  buildDotnetModule,
  jellyfin-ffmpeg,
  fontconfig,
  freetype,
  jellyfin-web,
  sqlite,
  fetchpatch,
}:

buildDotnetModule rec {
  pname = "jellyfin";
  version = "10.9.9"; # ensure that jellyfin-web has matching version

  src = fetchFromGitHub {
    owner = "jellyfin";
    repo = "jellyfin";
    rev = "v${version}";
    sha256 = "sha256-kck4VQiH+uZvASO1YxKze2pu8N+z5rqYJAXFVPc+ZJU=";
  };

  patches = fetchpatch {
    url = "https://github.com/jellyfin/jellyfin/commit/21f1813d82ca00eba9d2670889deeaab91c2f77e.patch?full_index=1";
    hash = "sha256-pawiYiPj+PmpvMyTRAVgGa4rrPaMBT2e9cbjnlHK0Zg=";
  };

  propagatedBuildInputs = [ sqlite ];

  projectFile = "Jellyfin.Server/Jellyfin.Server.csproj";
  executables = [ "jellyfin" ];
  nugetDeps = ./nuget-deps.nix;
  runtimeDeps = [
    jellyfin-ffmpeg
    fontconfig
    freetype
  ];
  dotnet-sdk = dotnetCorePackages.sdk_8_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_8_0;
  dotnetBuildFlags = [ "--no-self-contained" ];

  makeWrapperArgs = [
    "--add-flags" "--ffmpeg=${jellyfin-ffmpeg}/bin/ffmpeg"
    "--add-flags" "--webdir=${jellyfin-web}/share/jellyfin-web"
  ];

  passthru.tests = {
    smoke-test = nixosTests.jellyfin;
  };

  passthru.updateScript = ./update.sh;

  meta = with lib; {
    description = "Free Software Media System";
    homepage = "https://jellyfin.org/";
    # https://github.com/jellyfin/jellyfin/issues/610#issuecomment-537625510
    license = licenses.gpl2Plus;
    maintainers = with maintainers; [
      nyanloutre
      minijackson
      purcell
      jojosch
    ];
    mainProgram = "jellyfin";
    platforms = dotnet-runtime.meta.platforms;
  };
}
