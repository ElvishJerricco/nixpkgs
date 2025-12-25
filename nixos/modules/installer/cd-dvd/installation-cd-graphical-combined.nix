# This configuration uses a specialisation for each desired boot
# configuration, and a common parent configuration for all of
# them. This allows users to import this module alongside their own
# and get the full array of specialisations inheriting the users'
# settings.

{ lib, ... }:
{
  imports = [
    ./installation-cd-graphical-calamares-gnome.nix
    ./installation-cd-graphical-calamares-plasma6.nix
  ];
  isoImage.edition = "graphical";
  isoImage.configurationName = lib.mkDefault "GNOME (Linux LTS)";
  isoImage.gnome.enable = lib.mkDefault true;
  isoImage.plasma6.enable = lib.mkDefault false;

  specialisation = {
    gnome_latest_kernel.configuration =
      { config, ... }:
      {
        imports = [ ./latest-kernel.nix ];
        isoImage.configurationName = "GNOME (Linux ${config.boot.kernelPackages.kernel.version})";
      };

    plasma.configuration =
      { config, ... }:
      {
        isoImage.configurationName = "Plasma (Linux LTS)";
        isoImage.gnome.enable = false;
        isoImage.plasma6.enable = false;
      };

    plasma_latest_kernel.configuration =
      { config, ... }:
      {
        imports = [ ./latest-kernel.nix ];
        isoImage.edition = "graphical";
        isoImage.configurationName = "Plasma (Linux ${config.boot.kernelPackages.kernel.version})";
        isoImage.gnome.enable = false;
        isoImage.plasma6.enable = false;
      };
  };
}
