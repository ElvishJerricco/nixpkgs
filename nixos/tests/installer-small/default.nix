{ runTest }: {
  ext4 = runTest ./ext4.nix;
  foo = runTest ./foo.nix;
}
