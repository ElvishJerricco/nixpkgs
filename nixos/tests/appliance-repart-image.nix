# Tests building and running a GUID Partition Table (GPT) appliance image.
# "Appliance" here means that the image does not contain the normal NixOS
# infrastructure of a system profile and cannot be re-built via
# `nixos-rebuild`.

{ lib, ... }:

let
  rootPartitionLabel = "root";

  imageId = "nixos-appliance";
  imageVersion = "1-rc1";
in
{
  name = "appliance-gpt-image";

  meta.maintainers = with lib.maintainers; [ nikstur ];

  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      efiDirs =
        pkgs.runCommand "efi-dirs"
          {
            nativeBuildInputs = [
              (pkgs.nixos-systemd-boot-builder.override {
                util-linux = config.systemd.package.util-linux;
                systemd = config.systemd.package;
                bootspec = config.boot.bootspec.package;
                nix = config.nix.package;
                inherit (config.system.nixos) distroName;
              })
            ];
          }
          ''
            mkdir -p build/${config.boot.loader.efi.efiSysMountPoint}
            ${lib.optionalString (config.boot.loader.systemd-boot.xbootldrMountPoint != null) ''
              mkdir -p build/${config.boot.loader.systemd-boot.xbootldrMountPoint}
            ''}
            mkdir -p build/nix/var/nix/profiles/
            ln -s ${config.system.build.toplevel} build/nix/var/nix/profiles/system-1-link
            ln -s system-1-link build/nix/var/nix/profiles/system

            # Have to copy os-release, because RESOLVE_IN_ROOT
            mkdir build/etc
            cat ${config.system.build.etc}/etc/os-release > build/etc/os-release

            cat build/etc/os-release
            env SYSTEMD_RELAX_ESP_CHECKS=1 NIXOS_INSTALL_BOOTLOADER=1 SYSTEMD_LOG_LEVEL=debug \
              systemd-boot-builder \
              --root $(realpath build) \
              ${config.system.build.systemdBootBuilderConfig} \
              ${config.system.build.toplevel}

            mkdir $out
            mv build/${config.boot.loader.efi.efiSysMountPoint} $out/esp
            ${lib.optionalString (config.boot.loader.systemd-boot.xbootldrMountPoint != null) ''
              mv build/${config.boot.loader.systemd-boot.xbootldrMountPoint} $out/xbootldr
            ''}
          '';

    in
    {

      imports = [ ../modules/image/repart.nix ];

      virtualisation.directBoot.enable = false;
      virtualisation.mountHostNixStore = false;
      virtualisation.useEFIBoot = true;

      # TODO(raitobezarius): revisit this when #244907 lands
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = false;

      system.image.id = imageId;
      system.image.version = imageVersion;

      systemd.package = pkgs.systemd.overrideAttrs (old: {
        patches = old.patches ++ [ ./skip-checks.patch ];
      });

      virtualisation.fileSystems = lib.mkForce {
        "/" = {
          device = "/dev/disk/by-partlabel/${rootPartitionLabel}";
          fsType = "ext4";
        };
      };

      image.repart = {
        name = "appliance-gpt-image";
        # OVMF does not work with the default repart sector size of 4096
        sectorSize = 512;
        partitions = {
          "esp" = {
            contents = {
              "/".source = "${efiDirs}/esp";
            };
            repartConfig = {
              Type = "esp";
              Format = "vfat";
              # Minimize = "guess" seems to not work very well for vfat
              # partitions. It's better to set a sensible default instead. The
              # aarch64 kernel seems to generally be a little bigger than the
              # x86_64 kernel. To stay on the safe side, leave some more slack
              # for every platform other than x86_64.
              SizeMinBytes = if config.nixpkgs.hostPlatform.isx86_64 then "64M" else "96M";
            };
          };
          "xbootldr" = lib.mkIf (config.boot.loader.systemd-boot.xbootldrMountPoint != null) {
            contents = {
              "/".source = "${efiDirs}/xbootldr";
            };
            repartConfig = {
              Type = "xbootldr";
              Format = "vfat";
              SizeMinBytes = if config.nixpkgs.hostPlatform.isx86_64 then "64M" else "96M";
            };
          };
          "swap" = {
            repartConfig = {
              Type = "swap";
              Format = "swap";
              SizeMinBytes = "10M";
              SizeMaxBytes = "10M";
            };
          };
          "root" = {
            storePaths = [ config.system.build.toplevel ];
            repartConfig = {
              Type = "root";
              Format = config.fileSystems."/".fsType;
              Label = rootPartitionLabel;
              Minimize = "guess";
            };
          };
        };
      };
    };

  testScript =
    { nodes, ... }:
    ''
      import os
      import subprocess
      import tempfile

      tmp_disk_image = tempfile.NamedTemporaryFile()

      subprocess.run([
        "${nodes.machine.virtualisation.qemu.package}/bin/qemu-img",
        "create",
        "-f",
        "qcow2",
        "-b",
        "${nodes.machine.system.build.image}/${nodes.machine.image.repart.imageFile}",
        "-F",
        "raw",
        tmp_disk_image.name,
      ])

      # Set NIX_DISK_IMAGE so that the qemu script finds the right disk image.
      os.environ['NIX_DISK_IMAGE'] = tmp_disk_image.name

      with subtest("/etc/os-release contains the right fileds"):
        os_release = machine.succeed("cat /etc/os-release")
        t.assertIn('IMAGE_ID="${imageId}"', os_release)
        t.assertIn('IMAGE_VERSION="${imageVersion}"', os_release)
    '';
}
