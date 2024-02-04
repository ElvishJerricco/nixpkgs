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

  testScript = ''
    installer.start()
    installer.wait_for_unit("installed.target")

    with subtest("Shutdown system after installation"):
        installer.succeed("umount -R /mnt")
        installer.succeed("sync")
        installer.shutdown()

    target.state_dir = installer.state_dir
    with subtest("Boot new machine"):
        target.wait_for_unit("multi-user.target")


    target.shutdown()
  '';
}
