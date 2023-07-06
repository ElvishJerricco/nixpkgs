import ./make-test-python.nix ({ pkgs, lib, ... }: {
  name = "systemd-gpt-auto-generator";

  nodes.machine = {
    virtualisation = {
      useBootLoader = true;
      useEFIBoot = true;
      gptAuto.enable = true;
      luks.enable = true;
      memorySize = 2048;
    };

    boot.loader.timeout = 0;
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    boot.initrd.systemd.enable = true;
    boot.initrd.systemd.package = pkgs.systemd;
    boot.initrd.luks.forceLuksSupportInInitrd = true;
  };

  testScript = ''
    machine.start()
    machine.wait_for_console_text("Please enter passphrase for disk primary")
    machine.send_console("\n")
    machine.succeed("mount | grep '/dev/mapper/root on /'")
    machine.succeed("journalctl | grep 'Finished File System Check on /dev/gpt-auto-root.'")
  '';
})
