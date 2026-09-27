# SPDX-License-Identifier: MIT
#
# The pin readers: a function per pin system that reads its files into
# `sources`, the pinned trees a tree is built from, each carrying the
# identity its pin files record. Everything caisson does with a source
# is the same under every pin system; a reader is the whole of what a
# pin system contributes.
#
#   pins.flake inputs            the inputs Nix's flake evaluator resolved
#                                for the flake being evaluated (the
#                                `inputs` its `outputs` receives), with
#                                any `--override-input` in force; returns
#                                { sources; root; }, `root` from `self`
#   pins.flake-compat ./dir      the flake.lock beside a flake.nix in
#                                `dir`, resolved the way flake-compat
#                                does, stopping before the flake's
#                                `outputs`; nothing overrides it and it
#                                has no `self`; returns { sources; }
#   pins.npins ./npins           npins' sources.json in `dir`, each pin
#                                fetched as npins' generated default.nix
#                                fetches it; returns { sources; }
#   pins.gitRoot ./.             the `root` of a flakeless top in a git
#                                working tree: its revision when clean,
#                                marked dirty otherwise
#
# A source is the tree as its pin system hands it over (a flake input
# keeps its outputs, a fetched tree is { outPath; ... }), so it stands
# wherever an input stood, plus `pin`, the record of how it is pinned:
#
#   pin.system     "flake" (from either flake reader) or "npins"; the
#                  writer that moves the source follows from it
#   pin.files      { refs; revisions; }: the file holding the ref and
#                  the file holding the revision, relative to `pin.dir`
#                  when present and to the tree's root otherwise
#   pin.dir        the directory holding the pin files, as a path, for
#                  a reader given a directory; the root is not known to
#                  the reader, so relativizing happens where both are
#   pin.url        the ref as the pin files write it
#   pin.rev, pin.narHash, pin.lastModified
#                  the identity of the tree, where the pin system
#                  records it
#   pin.follows    for a flake input declared as a `follows`: the path
#                  of input names it follows from the root; its tree and
#                  identity are those of the input it lands on, and it
#                  has no lock entry of its own to move
#   pin.overridden `pins.flake` only: the resolved tree differs from
#                  the lock (an `--override-input` was in force), so
#                  `pin.url` describes the lock, not the tree
#
# A root is { outPath; dirty; rev?; dirtyRev?; lastModified?; narHash?; }.
#
# Builtins only.
{ ... }:
let

  flakeLock = import ./flake-lock.nix;
  npins = import ./npins.nix;

  present =
    names: attrs:
    builtins.listToAttrs (
      builtins.concatMap (
        n:
        if attrs ? ${n} then
          [
            {
              name = n;
              value = attrs.${n};
            }
          ]
        else
          [ ]
      ) names
    );

  identity = present [
    "rev"
    "narHash"
    "lastModified"
  ];

  flakeFiles = {
    refs = "flake.nix";
    revisions = "flake.lock";
  };

  fromLock =
    descriptor:
    {
      url = flakeLock.refToString descriptor.original;
    }
    // present [ "follows" ] descriptor;

  flake =
    inputs:
    let
      self =
        inputs.self or (throw ''
          caisson-core: pins.flake takes the inputs a flake's `outputs` receives,
          `self` included; it reads the root from `self`. For a flake.nix and
          flake.lock pair Nix does not evaluate, use pins.flake-compat.
        '');
      lock = flakeLock.readLock self.outPath;
      descriptors =
        if lock == null then { } else flakeLock.descriptors (flakeLock.checkVersion "pins.flake" lock);
      sourceOf =
        name: input:
        let
          descriptor = descriptors.${name} or null;
          lockedHash = if descriptor == null then null else descriptor.locked.narHash or null;
        in
        input
        // {
          pin = {
            system = "flake";
            files = flakeFiles;
            overridden = lockedHash != null && input ? narHash && input.narHash != lockedHash;
          }
          // identity input
          // (if descriptor == null then { } else fromLock descriptor);
        };
    in
    {
      sources = builtins.mapAttrs sourceOf (builtins.removeAttrs inputs [ "self" ]);
      root = {
        outPath = self.outPath;
        dirty = self ? dirtyRev;
      }
      // present [
        "rev"
        "dirtyRev"
        "lastModified"
        "narHash"
      ] self;
    };

  flake-compat =
    dir:
    let
      lock =
        let
          raw = flakeLock.readLock dir;
        in
        if raw == null then
          throw ''
            caisson-core: pins.flake-compat reads `${toString dir}/flake.lock`, which does
            not exist. Lock the flake (`nix flake lock` in that directory).
          ''
        else
          flakeLock.checkVersion "pins.flake-compat" raw;
      # A relative `path:` input lies inside the directory itself, so it
      # is located as a path value and never coerced to a store path: the
      # read stays valid under read-only evaluation (`nix flake check
      # --no-build`). Every other input is fetched from its locked attrs,
      # which read-only evaluation allows.
      treeOf =
        name: descriptor:
        if descriptor.relative then
          if descriptor.parent != [ ] then
            throw ''
              caisson-core: pins.flake-compat: input `${name}` of `${toString dir}` lands on
              a relative path input inside the input `${builtins.concatStringsSep "/" descriptor.parent}`,
              which is not supported; only relative path inputs of the flake itself are.
            ''
          else
            {
              outPath = if descriptor.locked.path == "" then dir else dir + "/${descriptor.locked.path}";
            }
        else
          let
            fetched = builtins.fetchTree (builtins.removeAttrs descriptor.locked [ "dir" ]);
            subdir = descriptor.locked.dir or "";
          in
          fetched // { outPath = fetched.outPath + (if subdir == "" then "" else "/" + subdir); };
      sourceOf =
        name: descriptor:
        let
          tree = treeOf name descriptor;
        in
        tree
        // {
          pin = {
            system = "flake";
            files = flakeFiles;
            inherit dir;
          }
          // identity (descriptor.locked // tree)
          // fromLock descriptor;
        };
    in
    {
      sources = builtins.mapAttrs sourceOf (flakeLock.descriptors lock);
    };

  npinsReader =
    dir:
    let
      file = dir + "/sources.json";
      data =
        if builtins.pathExists file then
          builtins.fromJSON (builtins.readFile file)
        else
          throw "caisson-core: pins.npins reads `${toString file}`, which does not exist.";
      sourceOf =
        _name: descriptor:
        npins.fetch descriptor
        // {
          pin = {
            system = "npins";
            files = {
              refs = "sources.json";
              revisions = "sources.json";
            };
            inherit dir;
            inherit (descriptor) url hash;
          }
          // present [
            "rev"
            "narHash"
          ] descriptor;
        };
    in
    {
      sources = builtins.mapAttrs sourceOf (npins.describe "pins.npins" data);
    };

  # The root of a flakeless top whose tree is a git working tree. It
  # needs an impure evaluation, as `nix-build` of a default.nix is,
  # since the working tree is not locked. A directory that is not a git
  # working tree has no revision to name, and its root is the directory.
  gitRoot =
    dir:
    if builtins.pathExists (dir + "/.git") then
      let
        fetched = builtins.fetchGit dir;
        zeros = "0000000000000000000000000000000000000000";
        clean = fetched ? rev && fetched.rev != zeros;
      in
      {
        outPath = fetched.outPath;
        dirty = !clean;
      }
      // (if clean then { inherit (fetched) rev; } else { })
      // present [
        "dirtyRev"
        "lastModified"
        "narHash"
      ] fetched
    else
      {
        outPath = dir;
        dirty = false;
      };

in
{
  overlay = _final: prev: {
    caisson-core = (prev.caisson-core or { }) // {
      pins = {
        inherit flake flake-compat gitRoot;
        npins = npinsReader;
      };
    };
  };
}
