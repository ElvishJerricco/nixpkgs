{ lib, buildFHSEnvChroot }:

# Similar to runInLinuxVM, except we run under a FHS user env instead
# of a VM. This allows you to use build systems that depend on the FHS
# without any sort of patching. Resulting binaries may not work on
# NixOS without wrapping them in FHS though.
drv: envArgs: let
  fhsWrapper = buildFHSEnvChroot ({
    name = "${drv.name}-fhs-wrapper";
    runScript = "$@";
  } // envArgs);
in lib.overrideDerivation drv (old: {
  builder = "${fhsWrapper}/bin/${fhsWrapper.name}";
  args = [old.builder] ++ old.args;
})
