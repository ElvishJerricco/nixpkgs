{ haskellLib }:

let inherit (haskellLib) doJailbreak;
in self: super: {
  haddock-library-ghcjs = doJailbreak super.haddock-library-ghcjs;
}
