{ lib, pkgs, ... }: let
  diskLayout = builtins.toFile "disk-layout" ''
    label: gpt
    label-id: c0660c98-914c-4eb0-812f-1cf92c9e5945

    size=512MiB, type="EFI System", uuid=ed62cdd4-addc-4f0d-9a8c-9755018ae3fc
    size=1GiB,   type="swap",       uuid=c53f6af5-d3c5-414a-a887-98742d00e90f
                 type="linux",      uuid=3f4bb431-10b5-4657-a7dd-9db61295c20d
  '';

in {
  name = "foo";
  imports = [./common.nix];
  nodes.installer = {
    boot.initrd.systemd.enable = true;
    systemd.services.format = {
      requiredBy = ["nixos-install.service"];
      before = ["nixos-install.service"];
      serviceConfig.Type = "oneshot";
      path = [pkgs.dosfstools pkgs.btrfs-progs pkgs.util-linux pkgs.systemd];
      script = ''
        sfdisk /dev/vda < ${diskLayout}
        udevadm settle
        mkfs.vfat /dev/disk/by-partuuid/ed62cdd4-addc-4f0d-9a8c-9755018ae3fc
        mkfs.btrfs /dev/disk/by-partuuid/3f4bb431-10b5-4657-a7dd-9db61295c20d
        mkswap /dev/disk/by-partuuid/c53f6af5-d3c5-414a-a887-98742d00e90f

        mkdir /mnt
        mount /dev/disk/by-partuuid/3f4bb431-10b5-4657-a7dd-9db61295c20d /mnt
        mkdir /mnt/boot
        mount /dev/disk/by-partuuid/ed62cdd4-addc-4f0d-9a8c-9755018ae3fc /mnt/boot
        swapon /dev/disk/by-partuuid/c53f6af5-d3c5-414a-a887-98742d00e90f
      '';
    };
  };
  nodes.target = {
    boot.initrd.systemd.enable = true;
    virtualisation.fileSystems = lib.mkForce {
      "/" = {
        device = "PARTUUID=3f4bb431-10b5-4657-a7dd-9db61295c20d";
        fsType = "btrfs";
      };
      "/boot" = {
        device = "PARTUUID=ed62cdd4-addc-4f0d-9a8c-9755018ae3fc";
        fsType = "vfat";
        options = [ "umask=0077" ];
      };
    };
    swapDevices = [{ device = "/dev/disk/by-partuuid/c53f6af5-d3c5-414a-a887-98742d00e90f"; }];
  };
}
