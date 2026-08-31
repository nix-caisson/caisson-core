# SPDX-License-Identifier: MIT
{

  description = "A minimal calculus for composing library overlays: identity, replacement, and deterministic order over plain builtins";

  outputs =
    { self }:
    {
      lib.caisson-core = import ./lib;
    };

}
