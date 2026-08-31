# SPDX-License-Identifier: MIT
{

  description = "Library overlay composition with identity, replacement, and deterministic order, over plain builtins";

  outputs =
    { self }:
    {
      lib.caisson-core = import ./lib;
    };

}
