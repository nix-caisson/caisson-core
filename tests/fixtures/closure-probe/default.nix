# SPDX-License-Identifier: MIT
# A module file that hands out what it closed over.
{ closure-lib, ... }:
{
  closureModules = closure-lib.caisson-core.modules;
  closureManifest = closure-lib.caisson-core.libManifest;
}
