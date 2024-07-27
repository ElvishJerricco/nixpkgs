{ lib, pkgs, ... }: let
  diskLayout0 = builtins.toFile "disk-layout" ''
    label: gpt
    label-id: c0660c98-914c-4eb0-812f-1cf92c9e5945

    size=512MiB, type="EFI System", uuid=ed62cdd4-addc-4f0d-9a8c-9755018ae3fc
    size=1GiB,   type="swap",       uuid=c53f6af5-d3c5-414a-a887-98742d00e90f
                 type="linux",      uuid=3f4bb431-10b5-4657-a7dd-9db61295c20d
  '';

  diskLayout1 = builtins.toFile "disk-layout" ''
    label: gpt
    label-id: f6b4a5af-edb7-4021-91b5-fd207772f1d8

    type="linux", uuid=d1cbac0f-9a3c-4796-809c-9324e7dc5e54
  '';

  diskLayout2 = builtins.toFile "disk-layout" ''
    label: gpt
    label-id: b3fd1ff3-70bc-43a3-af50-2d567406cf77

    type="linux", uuid=f906135e-a307-41f7-a8e7-502127489968
  '';

in {
  name = "foo";
  imports = [./common.nix];
  nodes.installer = {
    boot.initrd.systemd.enable = true;
    boot.supportedFilesystems.bcachefs = true;
    boot.supportedFilesystems.zfs = lib.mkForce false;
    boot.kernelPackages = pkgs.linuxPackages_latest;
    virtualisation.emptyDiskImages = lib.mkAfter [ 2048 2048 ];
    systemd.services.format = {
      requiredBy = ["nixos-install.service"];
      before = ["nixos-install.service"];
      serviceConfig.Type = "oneshot";
      path = [pkgs.dosfstools pkgs.btrfs-progs pkgs.bcachefs-tools pkgs.util-linux pkgs.systemd];
      script = ''
        sfdisk /dev/vda < ${diskLayout0}
        sfdisk /dev/vdc < ${diskLayout1}
        sfdisk /dev/vdd < ${diskLayout2}
        udevadm settle
        mkfs.vfat /dev/disk/by-partuuid/ed62cdd4-addc-4f0d-9a8c-9755018ae3fc
        mkfs.btrfs /dev/disk/by-partuuid/3f4bb431-10b5-4657-a7dd-9db61295c20d
        mkswap /dev/disk/by-partuuid/c53f6af5-d3c5-414a-a887-98742d00e90f

        mkdir /mnt
        mount /dev/disk/by-partuuid/3f4bb431-10b5-4657-a7dd-9db61295c20d /mnt
        mkdir /mnt/boot
        mount /dev/disk/by-partuuid/ed62cdd4-addc-4f0d-9a8c-9755018ae3fc /mnt/boot
        swapon /dev/disk/by-partuuid/c53f6af5-d3c5-414a-a887-98742d00e90f

        bcachefs format --metadata_replicas=2 --data_replicas=2 \
          -U 5473eba9-27a5-44a6-ad26-e37f852b0614 \
          /dev/disk/by-partuuid/d1cbac0f-9a3c-4796-809c-9324e7dc5e54 \
          /dev/disk/by-partuuid/f906135e-a307-41f7-a8e7-502127489968
      '';
    };
  };
  nodes.target = {
    boot.initrd.systemd.enable = true;
    boot.supportedFilesystems.zfs = lib.mkForce false;
    boot.kernelPackages = pkgs.linuxPackages_latest;
    systemd.services.unlock-bcachefs-data = {
      enable = false;
    };
    virtualisation.emptyDiskImages = [ 512 2048 2048 ];
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
      "/data" = {
        device = "UUID=5473eba9-27a5-44a6-ad26-e37f852b0614";
        fsType = "bcachefs";
        options = [
          "x-systemd.requires=dev-disk-by\\x2dpartuuid-d1cbac0f\\x2d9a3c\\x2d4796\\x2d809c\\x2d9324e7dc5e54.device"
          "x-systemd.requires=dev-disk-by\\x2dpartuuid-f906135e\\x2da307\\x2d41f7\\x2da8e7\\x2d502127489968.device"
          "defaults"
        ];
      };
    };
    swapDevices = [{ device = "/dev/disk/by-partuuid/c53f6af5-d3c5-414a-a887-98742d00e90f"; }];
  };
}
