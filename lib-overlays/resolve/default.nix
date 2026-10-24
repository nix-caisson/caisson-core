# SPDX-License-Identifier: MIT
#
# `caisson-core.resolve`: layered ecosystem-source resolution, the
# function in resolve.nix. `caisson-core.selectedSourceName`: the name
# of the pinned source a selection returns, from source-names.nix, or
# null where the selection returns a value it built in another way.
{ ... }:
{
  overlay = _final: prev: {
    caisson-core = (prev.caisson-core or { }) // {
      resolve = builtins.import ./resolve.nix;
      selectedSourceName =
        let
          names = builtins.import ./source-names.nix;
        in
        { selection, sources }: names.nameOf (selection (names.tagged sources));
    };
  };
}
