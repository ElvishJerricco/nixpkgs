import ./make-test-python.nix ({ pkgs, lib, ... }: {
  name = "kexec";
  nodes = {
    node1 = { ... }: {
      virtualisation.vlans = [ ];
      virtualisation.memorySize = 4 * 1024;
      virtualisation.useBootLoader = true;
      virtualisation.useEFIBoot = true;
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
    };
  };

  testScript = { nodes, ... }: ''
    # Test whether reboot via kexec works.
    node1.wait_for_unit("multi-user.target")
    node1.execute("systemctl kexec >&2 &", check_return=False)
    node1.connected = False
    node1.connect()
    node1.wait_for_unit("multi-user.target")
  '';
})
