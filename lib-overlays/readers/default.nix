# SPDX-License-Identifier: MIT
#
# The directory readers: registrations derived from the layout the
# conventions fix, so a tree that keeps the layout names only the
# directory.
#
#   mkModules ./modules        reads <dir>/<class>/<name> into the
#                              class-keyed registration mkLib takes as
#                              `modules` and as `configs`; the leaf is
#                              the `mkModule` of the integration that
#                              declares the class, found in the class
#                              index of the composed library
#                              (`caisson-core.classes.<class>`), applied
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
# directory is the class, whatever its name, and a class no composed
# integration declares is an error as well: registering through the
# index is what lets an integration that wraps another (declaring the
# same class later, with its own mkModule) see every module of the
# class. A tree with another layout registers by hand.
{ ... }:
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
    let
      classes = composedLib.caisson-core.classes or { };
      mkModuleOf =
        class:
        if classes ? ${class} then
          classes.${class}.mkModule
        else
          throw ''
            caisson-core: mkModules reads `${toString dir}/${class}`, but no integration
            composed in this library declares the class `${class}` (the declared
            classes are ${builtins.concatStringsSep ", " (builtins.attrNames classes)}).
            Compose the integration that owns the class, declare the class from an
            overlay (`contributeClasses`), or register the directory by hand with
            `caisson-core.mkModule "${class}"`.
          '';
    in
    builtins.mapAttrs (
      class: classDir:
      builtins.mapAttrs (_name: path: mkModuleOf class path) (entriesOf "mkModules" classDir)
    ) (subdirectoriesOf "mkModules" dir);

  mkLibOverlays =
    dir: mkLibOverlay:
    builtins.mapAttrs (_name: path: mkLibOverlay path) (entriesOf "mkLibOverlays" dir);

in
{
  overlay = _final: prev: {
    caisson-core = (prev.caisson-core or { }) // {
      inherit mkModules mkLibOverlays;
    };
  };
}
