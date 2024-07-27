{ lib, pkgs, ... }: let
  diskLayout = builtins.toFile "disk-layout" ''
    label: gpt
    label-id: c0660c98-914c-4eb0-812f-1cf92c9e5945

    size=512MiB, type="EFI System", uuid=ed62cdd4-addc-4f0d-9a8c-9755018ae3fc
    size=1GiB,   type="swap",       uuid=c53f6af5-d3c5-414a-a887-98742d00e90f
                 type="linux",      uuid=3f4bb431-10b5-4657-a7dd-9db61295c20d
  '';
in {
  name = "zfs-root";
  imports = [./common.nix];
  nodes.installer = {
    boot.supportedFilesystems.zfs = true;
    systemd.services.format = {
      requiredBy = ["nixos-install.service"];
      before = ["nixos-install.service"];
      serviceConfig.Type = "oneshot";
      path = [pkgs.dosfstools pkgs.zfs pkgs.util-linux];
      script = ''
        sfdisk /dev/vda < ${diskLayout}
        udevadm settle
        mkswap /dev/disk/by-partuuid/c53f6af5-d3c5-414a-a887-98742d00e90f -L swap
        zpool create rpool /dev/disk/by-partuuid/3f4bb431-10b5-4657-a7dd-9db61295c20d
        zfs create -o mountpoint=legacy rpool/root
        mkdir /mnt
        mount -t zfs rpool/root /mnt
        zfs create -o mountpoint=legacy rpool/root/usr
        mkdir /mnt/usr
        mount -t zfs rpool/root/usr /mnt/usr
        mkfs.vfat -n BOOT /dev/disk/by-partuuid/ed62cdd4-addc-4f0d-9a8c-9755018ae3fc
        mkdir /mnt/boot
        mount LABEL=BOOT /mnt/boot
      '';
    };
  };

  nodes.target = {
    boot.supportedFilesystems = [ "zfs" ];

    # Using by-uuid overrides the default of by-id, and is unique
    # to the qemu disks, as they don't produce by-id paths for
    # some reason.
    boot.zfs.devNodes = "/dev/disk/by-uuid/";
    networking.hostId = "00000000";

    virtualisation.fileSystems = lib.mkForce {
      "/" = {
        device = "rpool/root";
        fsType = "zfs";
      };
      "/usr" = {
        device = "rpool/root/usr";
        fsType = "zfs";
      };
      "/boot" = {
        device = "LABEL=BOOT";
        fsType = "vfat";
      };
    };

    swapDevices = [{ device = "/dev/disk/by-label/swap"; }];
  };
}
