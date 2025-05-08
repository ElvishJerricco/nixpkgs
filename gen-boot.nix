{
  lib,
  config,
  options,
  pkgs,
  modulesPath,
  ...
}:
let
  volid = "nixos-minimal-25.05-x86_64";

  limine = pkgs.limine.override { buildCDs = true; };

  getFrom =
    fname:
    (lib.head (
      lib.filter (
        { file, value, ... }: baseNameOf file == fname && value ? installBootLoader
      ) options.system.build.definitionsWithLocations
    )).value.installBootLoader;

  sdBootInstaller = getFrom "systemd-boot.nix";
  limineInstaller = getFrom "limine.nix";

  esp =
    let
      script = pkgs.buildPackages.writeShellApplication {
        name = "mkesp";
        runtimeInputs = [ pkgs.buildPackages.util-linux ];
        text = ''
          if [ "$(id -u)" != 0 ]; then
            exec unshare -rm "$0" "$@"
          fi
          mkdir chroot
          for f in /nix/store /proc /dev "$(pwd)"; do
            mkdir -p "./chroot$f"
            mount --rbind "$f" "./chroot$f"
          done
          mkdir -p chroot/${config.boot.loader.efi.efiSysMountPoint}
          mount --bind "$1" chroot/${config.boot.loader.efi.efiSysMountPoint}
          export NIXOS_INSTALL_BOOTLOADER=1
          export SYSTEMD_RELAX_ESP_CHECKS=1
          export SYSTEMD_OS_RELEASE=${config.environment.etc.os-release.source}
          mkdir -p ./chroot/nix/var/nix/profiles
          ln -s "${config.system.build.toplevel}" ./chroot/nix/var/nix/profiles/system-1-link
          ln -s system-1-link ./chroot/nix/var/nix/profiles/system
          chroot ./chroot ${limineInstaller} "${config.system.build.toplevel}"
          exec chroot ./chroot ${sdBootInstaller pkgs} "${config.system.build.toplevel}"
        '';
      };
    in
    pkgs.runCommand "esp" { } "mkdir $out; ${script}/bin/mkesp $out";

in
{
  imports = [
    "${modulesPath}/image/repart.nix"
    # "${modulesPath}/profiles/installation-device.nix"
  ];
  services.getty.autologinUser = "root";

  boot.loader.systemd-boot = {
    enable = true;
    enableRandomSeed = false;
  };
  boot.loader.efi = {
    canTouchEfiVariables = false;
  };
  boot.initrd.systemd = {
    enable = true;
    emergencyAccess = true;
  };
  hardware.enableAllHardware = true;

  fileSystems."/" = {
    device = "tmpfs";
    fsType = "tmpfs";
  };
  fileSystems."/nix/store" = {
    device = "/sysroot/iso/nix-store.squashfs";
    fsType = "squashfs";
    options = [ "loop" ];
  };
  fileSystems."/iso" = {
    device = "LABEL=${volid}";
    fsType = "iso9660";
    neededForBoot = true;
  };
  boot.initrd.availableKernelModules = [
    "loop"
    "iso9660"
  ];

  boot.loader.limine = {
    enable = true;
    biosSupport = true;
    efiSupport = false;
    bootDirectory = "/boot";
    enableEditor = true;
    extraConfig = ''
      serial: yes
    '';
  };

  boot.kernelParams = [
    "console=ttyS0"
    "console=tty0"
  ];

  system.build.installBootLoader = lib.mkForce (_: "");

  image.repart = {
    name = "gen-boot";
    split = true;
    extraBuildCommands = ''
      rm gen-boot.raw
      mkdir -p iso/boot iso/limine
      mv -v gen-boot.esp.raw esp.raw
      mv -v gen-boot.linux-generic.raw iso/nix-store.squashfs
      cp -v ${limine}/share/limine/limine-bios-cd.bin iso/limine/
      ${pkgs.xorriso}/bin/xorriso \
        -volume_date all_file_dates =$SOURCE_DATE_EPOCH \
        -as mkisofs \
        -R -r -J \
        -iso-level 3 \
        -volid ${volid} \
        -appid nixos \
        -publisher nixos \
        ./iso \
        --protective-msdos-label \
        -partition_offset 16 \
        -b limine/limine-bios-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -append_partition 2 0xef esp.raw -appended_part_as_gpt \
        -eltorito-alt-boot \
        -e --interval:appended_partition_2:all:: -no-emul-boot \
        -o gen-boot.iso

      ${limine}/bin/limine bios-install gen-boot.iso \
        --no-gpt-to-mbr-isohybrid-conversion
    '';

    mkfsOptions.vfat = [
      "--invariant"
      "-i ${lib.substring 0 8 (builtins.hashString "sha256" esp.outPath)}"
      "-n EFIBOOT"
    ];

    partitions."00-esp" = {
      contents."/".source = esp;
      repartConfig = {
        Type = "esp";
        Format = "vfat";
        Minimize = "guess";
      };
    };

    partitions."01-store" = {
      storePaths = [ config.system.build.toplevel ];
      stripNixStorePrefix = true;
      repartConfig = {
        Type = "linux-generic";
        Label = "NixOS";
        Format = "squashfs";
        Minimize = "best";
      };
    };
  };
}
