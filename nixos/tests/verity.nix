{ pkgs, lib, ... }: {
  name = "verity";

  nodes.machine = let
    corruptible = pkgs.writeText "corruptible" ''
      This is correct
    '';
  in {
    boot.kernelPatches = [
      {
        name = "fs-verity";
        patch = null;
        extraStructuredConfig = {
          FS_VERITY = lib.kernel.yes;
        };
      }
    ];
    virtualisation.useBootLoader = true;
    virtualisation.useEFIBoot = true;
    boot.loader.timeout = 0;
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    system.verity.enable = true;
    boot.initrd.systemd.enable = true;

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
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mount | grep 'overlay on /nix/store'")
    machine.succeed("stat /etc/corruptible")
    machine.fail("cat /etc/corruptible")
  '';
}
