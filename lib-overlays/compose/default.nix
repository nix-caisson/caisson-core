# SPDX-License-Identifier: MIT
#
# `caisson-core.compose`: the composition primitive, defined in
# lib/default.nix (it is what composes this entry) and contributed to
# the namespace here so a composed library carries it.
{ compose, ... }:
{
  overlay = _final: prev: {
    caisson-core = (prev.caisson-core or { }) // {
      inherit compose;
    };
  };
}
