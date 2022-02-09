{ ... }: {
  imports = [./nixos/modules/virtualisation/qemu-vm.nix];

  security.pam.zfs.enableEncryptedHome = true;
  security.pam.zfs.homes = "tank/home";
  networking.hostId = "deadbeef";
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.extraPools = ["tank"];
  boot.zfs.requestEncryptionCredentials = false;
  documentation.enable = false;

  services.getty.autologinUser = "root";
  services.openssh.enable = true;

  users.users.will = {
    isNormalUser = true;
  };

  virtualisation = {
    cores = 8;
    memorySize = 8192;
    graphics = false;
    forwardPorts = [{ from = "host"; host.port = 2222; guest.port = 22; }];
  };
}
