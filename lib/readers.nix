# SPDX-License-Identifier: MIT
#
# The directory readers: registrations derived from the layout the
# conventions fix, so a tree that keeps the layout names only the
# directory.
#
#   mkModules ./modules        reads <dir>/<class>/<name> into the
#                              class-keyed registration mkLib takes as
#                              `modules` and as `configs`; the leaf is
#                              `caisson-core.mkModule <class>` applied
#                              to the entry's directory.
#   mkLibOverlays ./lib-overlays
#                              reads <dir>/<name> into the registration
#                              mkLib takes as `libOverlays`; the leaf is
#                              `mkLibOverlay` applied to the entry's
#                              directory.
#
# Both return the function mkLib takes (`lib: { ... }` and
# `mkLibOverlay: { ... }`), so the call sites read
# `modules = caisson-core.mkModules ./modules;`. An entry is a
# directory holding a default.nix, a symlink to one included, and
# anything else in a directory being read is an error: a stray file
# cannot silently vanish from a registry. The first level of a modules
# directory is the class, whatever its name; nothing is reserved. A
# tree with another layout registers by hand.
#
# This file uses builtins only, on purpose.  Nothing here may
# reference nixpkgs' lib (or any other library).

let

  # The subdirectories of `dir`, name -> path; any other entry throws.
  subdirectoriesOf =
    what: dir:
    builtins.mapAttrs (
      name: type:
      if type == "directory" || type == "symlink" then
        dir + "/${name}"
      else
        throw ''
          caisson-core: ${what} reads `${toString dir}`, where every entry is a
          directory, but `${name}` is a file. Move it out of the directory being
          read, or register by hand.
        ''
    ) (builtins.readDir dir);

  # The entries of `dir`, name -> path: every subdirectory holding a
  # default.nix; a subdirectory without one throws.
  entriesOf =
    what: dir:
    builtins.mapAttrs (
      name: path:
      if builtins.pathExists (path + "/default.nix") then
        path
      else
        throw ''
          caisson-core: ${what} reads `${toString dir}`, where every entry is a
          directory holding a default.nix, but `${name}` holds none.
        ''
    ) (subdirectoriesOf what dir);

  mkModules =
    dir: composedLib:
    builtins.mapAttrs (
      class: classDir:
      builtins.mapAttrs (_name: path: composedLib.caisson-core.mkModule class path) (
        entriesOf "mkModules" classDir
      )
    ) (subdirectoriesOf "mkModules" dir);

  mkLibOverlays =
    dir: mkLibOverlay:
    builtins.mapAttrs (_name: path: mkLibOverlay path) (entriesOf "mkLibOverlays" dir);

in
{
  inherit mkModules mkLibOverlays;
}
