# SPDX-License-Identifier: MIT
{

  description = "Library overlay composition with identity, replacement, and deterministic order, over plain builtins";

  # An adapter over default.nix, the entry, for consumers that take
  # caisson-core as a flake.
  outputs =
    { self }:
    {
      lib.caisson-core = import ./.;
    };

}
