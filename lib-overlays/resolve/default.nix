# SPDX-License-Identifier: MIT
#
# `caisson-core.resolve`: layered ecosystem-source resolution, the
# function in resolve.nix.
{ ... }:
{
  overlay = _final: prev: {
    caisson-core = (prev.caisson-core or { }) // {
      resolve = import ./resolve.nix;
    };
  };
}
