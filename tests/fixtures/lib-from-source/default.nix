# SPDX-License-Identifier: MIT
#
# An overlay that loads a library from a source and merges it into the
# composed library, the way an integration brings in the library of an
# ecosystem. The names it adds come from the source, so it reads the
# source the composition supplies for the ecosystem `probe-lib` from
# `prev.caisson-core.ecosystemSrc`, and fails where it is composed
# when the composition supplies none.
{ ... }:
{
  imports = [ ];
  overlay =
    _final: prev:
    let
      src = prev.caisson-core.ecosystemSrc "probe-lib";
    in
    prev
    // builtins.import (
      if src == null then builtins.throw "lib-from-source: no `probe-lib` source" else src + "/lib"
    );
}
