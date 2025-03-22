{ runTest }: {
  ext4 = runTest ./ext4.nix;
  foo = runTest ./foo.nix;
  zfsroot = runTest ./zfsroot.nix;
  lvm2 = runTest ./lvm2.nix;
  repart-tmpfs = runTest ./repart-tmpfs.nix;
}
