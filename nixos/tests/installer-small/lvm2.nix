# Create two physical LVM partitions combined into one volume group
# that contains the logical swap and root partitions.
{ lib, pkgs, ... }: let
  diskLayout = builtins.toFile "disk-layout" ''
    label: gpt
    label-id: c0660c98-914c-4eb0-812f-1cf92c9e5945

    size=512MiB, type="EFI System", uuid=ed62cdd4-addc-4f0d-9a8c-9755018ae3fc
    size=3GiB,   type="Linux LVM",  uuid=c53f6af5-d3c5-414a-a887-98742d00e90f
                 type="Linux LVM",  uuid=3f4bb431-10b5-4657-a7dd-9db61295c20d
  '';
in {
  name = "lvm2";
  imports = [./common.nix];

  nodes.installer.systemd.services.format = {
    requiredBy = ["nixos-install.service"];
    before = ["nixos-install.service"];
    serviceConfig.Type = "oneshot";
    path = [pkgs.dosfstools pkgs.lvm2 pkgs.xfsprogs pkgs.util-linux];
    script = ''
      sfdisk /dev/vda < ${diskLayout}
      udevadm settle
      mkfs.vfat /dev/disk/by-partuuid/ed62cdd4-addc-4f0d-9a8c-9755018ae3fc
      pvcreate \
        /dev/disk/by-partuuid/c53f6af5-d3c5-414a-a887-98742d00e90f \
        /dev/disk/by-partuuid/3f4bb431-10b5-4657-a7dd-9db61295c20d
      vgcreate MyVolGroup \
        /dev/disk/by-partuuid/c53f6af5-d3c5-414a-a887-98742d00e90f \
        /dev/disk/by-partuuid/3f4bb431-10b5-4657-a7dd-9db61295c20d
      lvcreate --size 1G --name swap MyVolGroup
      lvcreate --extents 100%FREE --name nixos MyVolGroup
      mkswap /dev/MyVolGroup/swap
      swapon /dev/MyVolGroup/swap
      mkfs.xfs /dev/MyVolGroup/nixos
      mkdir /mnt
      mount /dev/MyVolGroup/nixos /mnt
      mkdir /mnt/boot
      mount /dev/disk/by-partuuid/ed62cdd4-addc-4f0d-9a8c-9755018ae3fc /mnt/boot
    '';
  };
  nodes.target = { config, ... }: {
    boot.initrd.services.lvm.enable = config.boot.initrd.systemd.enable;

    virtualisation.fileSystems = lib.mkForce {
      "/" = {
        device = "/dev/MyVolGroup/nixos";
        fsType = "xfs";
      };
      "/boot" = {
        device = "/dev/disk/by-partuuid/ed62cdd4-addc-4f0d-9a8c-9755018ae3fc";
        fsType = "vfat";
      };
    };
    swapDevices = [{ device = "/dev/MyVolGroup/swap"; }];
  };
}
