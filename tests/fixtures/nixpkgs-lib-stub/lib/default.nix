# SPDX-License-Identifier: MIT
#
# A stand-in for nixpkgs' `lib` directory with the shape the
# nixpkgs-lib entry relies on: an extensible fixpoint carrying
# `extend` and nothing else beside its functions, the way nixpkgs'
# own lib/default.nix builds itself. `stubReadsSelf` reads
# `stubIncrement` through self, which shows that a later override in
# the composed lib does not reach upstream's internal references.
let
  rattrs = self: {
    stubIncrement = n: n + 1;
    stubReadsSelf = self.stubIncrement 10;
  };
  makeExtensible =
    rattrs:
    let
      self = rattrs self // {
        extend = f: makeExtensible (self': rattrs self' // f self' (rattrs self'));
      };
    in
    self;
in
makeExtensible rattrs
