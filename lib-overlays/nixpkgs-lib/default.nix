# SPDX-License-Identifier: MIT
#
# The polyfill that brings nixpkgs' library into a composition. It is
# the one file of caisson-core that knows nixpkgs: the names of the
# sources that carry its library, and where the library sits in them.
# The manifest records this file as the origin of the `nixpkgs-lib`
# entry, so a reader of a composition's history lands here.
#
# What it does: it finds the source that supplies the library and
# merges that source's `lib` into the composed library, as the source
# fixes it. caisson-core calls no function of it.
#
# The source is, in order:
#
#   - `src`, where the caller of `mkNixpkgsLibEntry` names one;
#   - the source the composition supplies for the ecosystem
#     `nixpkgs-lib`: the library part declared separately, the
#     nixpkgs.lib mirror or nixpkgs' `lib` directory;
#   - the source the composition supplies for the ecosystem `nixpkgs`:
#     a nixpkgs checkout, one pin supplying every part.
#
# What a composition supplies for an ecosystem is read from
# `prev.caisson-core.ecosystemSrc`, which caisson-core's entries
# publish from the arguments of the mkLib call they are made for (the
# declared default, else the pinned source of that exact name). The
# entry is composed after those entries, so the value is there, and it
# is the source of the composition this entry is composed into,
# whichever tree registered the entry.
#
# With no source the entry is still made, and it fails where it is
# composed, naming the declaration: a composition that never composes
# it needs no nixpkgs.
#
# nixpkgs' lib/default.nix builds its fixpoint with a bootstrap
# makeExtensible that exposes `extend` only, no `__unfix__`, so the
# library cannot be re-tied over the composed fixpoint here. An
# overlay composed later overrides a name for readers of the composed
# library, and not for upstream's internal references.
#
# Unlike caisson-core's other overlay files, this one is not composed
# into every library: it is published under the key `nixpkgs-lib`,
# an overlay that needs upstream's functions imports it, and a
# same-key entry replaces it. It uses builtins only.
closure: {
  imports = [ ];
  overlay =
    _final: prev:
    let
      # Null for every name in a library caisson-core's entries are
      # not part of.
      supplied = (prev.caisson-core or { }).ecosystemSrc or (_name: null);
      src =
        if closure ? src then
          closure.src
        else if supplied "nixpkgs-lib" != null then
          supplied "nixpkgs-lib"
        else
          supplied "nixpkgs";
      root =
        if src == null then
          builtins.throw ''
            caisson-core: the `nixpkgs-lib` entry has no source. Declare
            `defaultEcosystemSrc.nixpkgs-lib` (the nixpkgs.lib mirror, or nixpkgs'
            `lib` directory) or `defaultEcosystemSrc.nixpkgs` (a nixpkgs checkout)
            in the mkLib call, or pin a source named exactly `nixpkgs-lib` or
            `nixpkgs` in the `sources` passed to mkLib.
          ''
        else
          "${src}";
      # A tree holding the `lib` directory, or that directory.
      libDir = if builtins.pathExists "${root}/lib/default.nix" then "${root}/lib" else root;
    in
    prev // builtins.import libDir;
}
