# SPDX-License-Identifier: MIT
# Imports its sibling from the registry of the composition that
# registered it, where the sibling carries its key.
{ closure-lib, ... }:
{
  imports = [ closure-lib.caisson-core.libManifest.pkgOverlays.extra ];
  overlay = _final: prev: { base = prev.extra + "+base"; };
}
