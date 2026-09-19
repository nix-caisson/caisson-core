# SPDX-License-Identifier: MIT
#
# A stand-in for nixpkgs' `lib` directory with the shape the
# nixpkgs-lib entry relies on: an extensible fixpoint carrying
# `__unfix__` (the raw self-function) and `extend`. `stubReadsSelf`
# reads `stubIncrement` through self, so a composition that re-ties
# this over its own fixpoint sees a later override of `stubIncrement`
# there.
let
  fix =
    f:
    let
      x = f x;
    in
    x;
  rattrs = self: {
    stubIncrement = n: n + 1;
    stubReadsSelf = self.stubIncrement 10;
  };
  makeExtensible =
    rattrs:
    fix (
      self:
      (rattrs self)
      // {
        __unfix__ = rattrs;
        extend = f: makeExtensible (self': rattrs self' // f self' (rattrs self'));
      }
    );
in
makeExtensible rattrs
