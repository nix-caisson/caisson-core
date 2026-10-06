# SPDX-License-Identifier: MIT
#
# The directory readers: registrations derived from the layout the
# conventions fix, so a tree that keeps the layout names only the
# directory.
#
#   mkModules ./modules        reads <dir>/<class>/<name> into the
#                              class-keyed registrations mkLib takes as
#                              `modules` and as `configs`; the leaf is
#                              the `mkModule` of the integration that
#                              declares the class, found in the class
#                              index of the library
#                              (`caisson-core.classes.<class>`), applied
#                              to the directory of the entry.
#   mkLibOverlays ./lib-overlays
#                              reads <dir>/<name> into the registrations
#                              mkLib takes as `libOverlays`; the leaf is
#                              `caisson-core.mkLibOverlay` of the
#                              library, applied to the directory of the
#                              entry.
#   mkPkgOverlays ./pkg-overlays
#                              reads <dir>/<name> into the registrations
#                              mkLib takes as `pkgOverlays`; the leaf is
#                              `caisson-core.mkPkgOverlay` of the
#                              library, applied to the directory of the
#                              entry.
#
# A reader belongs to the library it is read from and uses the class
# index and the constructors of that library. The registry functions
# of mkLib each receive a library, so a call site takes the reader
# from it: `modules = lib: lib.caisson-core.mkModules ./modules;`. A
# composition that registers another `caisson-core/readers` entry gets
# that entry's readers at every such call site. An entry is a
# directory holding a default.nix, a symlink to such a directory
# included, and anything else in a directory being read is an error:
# a stray file
# cannot silently vanish from a registry. The first level of a modules
# directory is the class, whatever its name, and a class no composed
# integration declares is an error as well: registering through the
# index is what lets an integration that wraps another (declaring the
# same class later, with its mkModule) see every module of the
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
        builtins.throw ''
          caisson-core: ${what} reads `${builtins.toString dir}`, where every entry is a
          directory, but `${name}` is a file. Move it out of the directory being
          read, or register by hand.
        ''
    ) (builtins.readDir dir);

  # The entries of `dir`, name -> path: every subdirectory holding a
  # default.nix; a subdirectory without a default.nix throws.
  entriesOf =
    what: dir:
    builtins.mapAttrs (
      name: path:
      if builtins.pathExists (path + "/default.nix") then
        path
      else
        builtins.throw ''
          caisson-core: ${what} reads `${builtins.toString dir}`, where every entry is a
          directory holding a default.nix, but `${name}` holds none.
        ''
    ) (subdirectoriesOf what dir);

  mkModules =
    composedLib: dir:
    let
      classes = composedLib.caisson-core.classes or { };
      mkModuleOf =
        class:
        if classes ? ${class} then
          classes.${class}.mkModule
        else
          builtins.throw ''
            caisson-core: mkModules reads `${builtins.toString dir}/${class}`, but no integration
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
    lib: dir:
    builtins.mapAttrs (_name: path: lib.caisson-core.mkLibOverlay path) (entriesOf "mkLibOverlays" dir);

  mkPkgOverlays =
    lib: dir:
    builtins.mapAttrs (_name: path: lib.caisson-core.mkPkgOverlay path) (entriesOf "mkPkgOverlays" dir);

in
{
  # Each reader is bound to the lib it is read from: the class index
  # and the entry constructors it uses are those of that lib.
  overlay = final: prev: {
    caisson-core = (prev.caisson-core or { }) // {
      mkModules = mkModules final;
      mkLibOverlays = mkLibOverlays final;
      mkPkgOverlays = mkPkgOverlays final;
    };
  };
}
