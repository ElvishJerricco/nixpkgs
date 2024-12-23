{ lib, config, pkgs, ... }:

{
  options.system.verity.enable = lib.mkEnableOption "verity";
  config = lib.mkIf config.system.verity.enable {
    system.systemBuilderCommands = ''
      if [ -n "''${closureInfo:+x}" ]; then
        xargs realpath --no-symlinks --relative-base /nix/store < "$closureInfo/store-paths" > ./store-paths
        # It's important that we don't mark /nix/store as opaque, so
        # that users can still have packages installed outside of their system
        # closure. The fact that ./store-paths only contains the store
        # paths themselves, and not the parent directory, ensures this property.
        tar -C /nix/store --verbatim-files-from --files-from=./store-paths --hard-dereference --create | ${pkgs.verity-ball}/bin/verity-ball > ./tmp.tar
        rm ./store-paths

        # This namespace uuid was generated randomly when this code was authored.
        # The resulting uuid is different for every build, but still deterministic,
        # because the uuid name is the derivation's outpath.
        uuid=$(${pkgs.util-linux}/bin/uuidgen --sha1 -n 'd80563fb-cef2-4529-88b3-b928be904f1b' -N "$out")

        ${pkgs.erofs-utils}/bin/mkfs.erofs -U "$uuid" --tar=headerball "$out/closure-meta.erofs" ./tmp.tar
        rm ./tmp.tar
      fi
    '';

    system.preSwitchChecks.verity = ''
      find /nix/store -type f -exec ${pkgs.fsverity-utils}/bin/fsverity enable {} \;
    '';

    boot.initrd.availableKernelModules = [ "overlay" "erofs" "loop" ];
    boot.initrd.systemd = {
      services.verity-overlay = {
        requiredBy = [ "initrd.target" ];
        before = [ "initrd-fs.target" ];
        unitConfig.DefaultDependencies = false;
        unitConfig.RequiresMountsFor = "/sysroot/nix/store";
        requires = [ "initrd-find-nixos-closure.service" ];
        after = [ "initrd-find-nixos-closure.service" ];
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        script = ''
          mkdir /run/closure-meta
          mount -o ro -t erofs /sysroot/$(readlink /nixos-closure)/closure-meta.erofs /run/closure-meta
          mount -t overlay -o verity=require,relatime,redirect_dir=on,metacopy=on,lowerdir=/run/closure-meta:/sysroot/nix/store,ro overlay /sysroot/nix/store
        '';
      };
    };
  };
}
