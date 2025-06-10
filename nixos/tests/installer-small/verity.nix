{
  lib,
  pkgs,
  nodes,
  ...
}:
let
  diskLayout = builtins.toFile "disk-layout" ''
    label: gpt
    label-id: c0660c98-914c-4eb0-812f-1cf92c9e5945

    size=512MiB, type="EFI System", uuid=ed62cdd4-addc-4f0d-9a8c-9755018ae3fc
    size=1GiB,   type="swap",       uuid=c53f6af5-d3c5-414a-a887-98742d00e90f
                 type="linux",      uuid=3f4bb431-10b5-4657-a7dd-9db61295c20d
  '';

  kconfig = {
    boot.kernelPatches = [
      {
        name = "fs-verity";
        patch = null;
        extraStructuredConfig = {
          FS_VERITY = lib.kernel.yes;
        };
      }
    ];
  };

  corruptible = pkgs.writeText "corruptible" ''
    This is correct
  '';
in
{
  name = "ext4";
  imports = [ ./common.nix ];
  nodes.installer = {
    imports = [ kconfig ];
    nix.settings.fsverity-store-paths = true;
    nix.package = pkgs.nix.overrideAttrs (old: {
      patches = old.patches or [ ] ++ [ ./verity-nix.patch ];
      buildInputs = old.buildInputs or [ ] ++ [ pkgs.fsverity-utils ];
    });
    systemd.services.format = {
      requiredBy = [ "nixos-install.service" ];
      before = [ "nixos-install.service" ];
      serviceConfig.Type = "oneshot";
      path = [
        pkgs.dosfstools
        pkgs.e2fsprogs
        pkgs.util-linux
      ];
      script = ''
        sfdisk ${nodes.target.virtualisation.bootLoaderDevice} < ${diskLayout}
        udevadm settle
        mkswap /dev/disk/by-partuuid/c53f6af5-d3c5-414a-a887-98742d00e90f -L swap
        mkfs.ext4 -O verity /dev/disk/by-partuuid/3f4bb431-10b5-4657-a7dd-9db61295c20d
        mkdir /mnt
        mount /dev/disk/by-partuuid/3f4bb431-10b5-4657-a7dd-9db61295c20d /mnt
        mkfs.vfat -n BOOT /dev/disk/by-partuuid/ed62cdd4-addc-4f0d-9a8c-9755018ae3fc
        mkdir /mnt/boot
        mount LABEL=BOOT /mnt/boot
      '';
    };
  };

  nodes.target = {
    imports = [ kconfig ];
    boot.initrd.systemd.enable = true;
    system.verity.enable = true;
    virtualisation.fileSystems = lib.mkForce {
      "/" = {
        device = "/dev/disk/by-partuuid/3f4bb431-10b5-4657-a7dd-9db61295c20d";
        fsType = "ext4";
      };
      "/boot" = {
        device = "LABEL=BOOT";
        fsType = "vfat";
      };
    };

    environment.etc.corruptible.source = corruptible;
    boot.initrd.systemd.extraBin.fsverity = "${pkgs.fsverity-utils}/bin/fsverity";
    boot.initrd.systemd.services.create-corruption = {
      requiredBy = [ "initrd.target" ];
      before = [ "verity-overlay.service" ];
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = "/sysroot/nix/store";
      };
      serviceConfig.Type = "oneshot";
      script = ''
        rm /sysroot${corruptible}
        echo 'This is incorrect' > /sysroot${corruptible}
        fsverity enable /sysroot${corruptible}
      '';
    };

    systemd.services.check-corruption = {
      requiredBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      path = [ pkgs.util-linux ];
      script = ''
        set -x
        mount | grep 'overlay on /nix/store'
        stat /etc/corruptible
        ! cat /etc/corruptible > /dev/null
      '';
    };
  };
}
