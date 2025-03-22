{ lib, pkgs, ... }: let
  commonConfig = {
    imports = [
      ../../modules/profiles/base.nix
      ../common/auto-format-root-device.nix
    ];
    # builds stuff in the VM, needs more juice
    virtualisation.diskSize = 8 * 1024;
    virtualisation.cores = 8;
    virtualisation.memorySize = 2048;

    # both installer and target need to use the same drive
    virtualisation.diskImage = "./target.qcow2";

    environment.systemPackages = [ pkgs.jq ];

    nix.settings = {
      substituters = lib.mkForce [];
      hashed-mirrors = null;
      connect-timeout = 1;
    };
  };
in {
  nodes.installer = { nodes, config, ... }: {
    imports = [
      commonConfig
    ];
    virtualisation.fileSystems."/".autoFormat = config.boot.initrd.systemd.enable;
    virtualisation.emptyDiskImages = [ 512 ];
    virtualisation.rootDevice = "/dev/vdb";
    boot.loader.timeout = 0;
    boot.loader.systemd-boot.enable = true;
    hardware.enableAllFirmware = lib.mkForce false;

    systemd = {
      targets.installed.requiredBy = ["multi-user.target"];

      services.nixos-install = {
        requiredBy = ["installed.target"];
        serviceConfig.Type = "oneshot";
        path = [config.nix.package];
        serviceConfig.ExecStart = "${pkgs.nixos-install-tools}/bin/nixos-install --no-channel-copy --no-root-passwd --system ${nodes.target.system.build.toplevel}";
      };
    };
  };

  nodes.target = { modulesPath, ... }: {
    imports = [
      commonConfig
    ];

    system.switch.enable = true;

    virtualisation.useBootLoader = true;
    virtualisation.useEFIBoot = true;
    virtualisation.useDefaultFilesystems = false;
    virtualisation.efi.keepVariables = false;

    boot.loader.timeout = 0;
    boot.loader.systemd-boot.enable = true;

    hardware.enableAllFirmware = lib.mkForce false;
  };

  testScript = { nodes, ... }: ''
    installer.start()
    installer.wait_for_unit("installed.target")

    # A bunch of crap is dumped here just for the repart-tmpfs test
    # because I never added a way for each test to customize the testScript

    with subtest("Shutdown system after installation"):
        start_size = int(installer.succeed("findmnt --json --target /mnt/nix | jq -r .filesystems[].source | xargs lsblk -b --json | jq .blockdevices[].size"))
        installer.succeed("umount -R /mnt")
        installer.succeed("sync")
        installer.shutdown()

    target.state_dir = installer.state_dir
    import subprocess
    subprocess.run([
      "${nodes.target.virtualisation.qemu.package}/bin/qemu-img",
      "resize",
      target.state_dir / "target.qcow2",
      "+2G",
    ])
    with subtest("Boot new machine"):
        target.wait_for_unit("multi-user.target")
        new_size = int(target.succeed("findmnt --json --target /nix | jq -r .filesystems[].source | xargs lsblk -b --json | jq .blockdevices[].size"))
        assert new_size > start_size, "Partition didn't grow"


    target.shutdown()
  '';
}
