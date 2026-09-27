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
#   pin.url        the ref as the pin files write it (null for a flake
#                  input its lock does not name)
#   pin.rev, pin.narHash, pin.lastModified
#                  the identity of the tree, where the pin system
#                  records it
#   pin.follows    flake readers: for an input declared as a `follows`,
#                  the path of input names it follows from the root; its
#                  tree and identity are those of the input it lands on,
#                  and it has no lock entry of its own to move. Null for
#                  every other input.
#
# The names of a flake input's `pin` are fixed and its values lazy, as
# with the fields of a root (below), since `pins.flake` reads the lock
# from `self`.
#   pin.overridden `pins.flake` only: the resolved tree differs from
#                  the lock (an `--override-input` was in force), so
#                  `pin.url` describes the lock, not the tree
#
# A root is { outPath; dirty; rev; shortRev; dirtyRev; dirtyShortRev;
# lastModified; lastModifiedDate; narHash; }, the source-info fields a
# flake's `self` carries, each null where the reader has none. The
# names are fixed and the values lazy: inside a flake's `outputs`,
# asking which attributes `self` has forces the outputs being computed,
# so a root read from `self` can be taken apart only by its values.
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

  # The source-info fields a flake's `self` carries beside `outPath`,
  # which a root keeps, so whatever read them from `self` reads them
  # from the root.
  rootFields = [
    "rev"
    "shortRev"
    "dirtyRev"
    "dirtyShortRev"
    "lastModified"
    "lastModifiedDate"
    "narHash"
  ];

  # A root from `info`: every field of `rootFields`, null where `info`
  # has none, with values read lazily.
  mkRoot =
    outPath: dirty: info:
    {
      inherit outPath dirty;
    }
    // builtins.listToAttrs (
      builtins.map (name: {
        inherit name;
        value = info.${name} or null;
      }) rootFields
    );

  flakeFiles = {
    refs = "flake.nix";
    revisions = "flake.lock";
  };

  # The part of a flake input's `pin` that its lock records: the ref and,
  # for a `follows`, the path it follows (null otherwise). The names are
  # fixed and the values lazy, since `pins.flake` reads the lock from
  # `self`, which the flake's outputs cannot read while they are being
  # computed; `descriptor` is null for an input the lock does not name.
  fromLock = descriptor: {
    url = if descriptor == null then null else flakeLock.refToString descriptor.original;
    follows = if descriptor == null then null else descriptor.follows or null;
  };

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
      # An input handed over as a bare path or store-path string, as a
      # hand-wired flake or `callConsumerFlake`'s pool may pass one, is
      # a tree with that out path.
      sourceOf =
        name: raw:
        let
          input = if builtins.isAttrs raw then raw else { outPath = raw; };
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
          // fromLock descriptor;
        };
    in
    {
      sources = builtins.mapAttrs sourceOf (builtins.removeAttrs inputs [ "self" ]);
      root = mkRoot self.outPath (self ? dirtyRev) self;
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
      # Every node of the lock as flake-compat makes it: a flake node is
      # the flake, its `outputs` applied to its own inputs and itself,
      # decorated with `inputs`, `outputs`, `sourceInfo`, `outPath` and
      # `_type`, as Nix hands a flake input over; a `flake = false` node
      # is its source tree. Nodes resolve lazily, so an input's inputs
      # are fetched and evaluated only when read.
      #
      # A relative `path:` node of the flake itself lies inside the
      # directory, so it is located as a path value and never coerced to
      # a store path: the read stays valid under read-only evaluation
      # (`nix flake check --no-build`). Every other node is fetched from
      # its locked attrs, which read-only evaluation allows. The root is
      # the directory and is never evaluated: its `outputs` are not what
      # the reader is for.
      nodes = builtins.mapAttrs (
        key: node:
        let
          locked = node.locked or { };
          relative = (locked.type or null) == "path" && builtins.substring 0 1 (locked.path or "/") != "/";
          parent = node.parent or [ ];
          sourceInfo =
            if relative then
              if parent != [ ] then
                throw ''
                  caisson-core: pins.flake-compat: the lock node `${key}` of `${toString dir}` is a
                  relative path input inside the input `${builtins.concatStringsSep "/" parent}`,
                  which is not supported; only relative path inputs of the flake itself are.
                ''
              else
                { outPath = if locked.path == "" then dir else dir + "/${locked.path}"; }
            else
              builtins.fetchTree ((node.info or { }) // builtins.removeAttrs locked [ "dir" ]);
          subdir = if relative then "" else locked.dir or "";
          outPath = sourceInfo.outPath + (if subdir == "" then "" else "/" + subdir);
          inputs = builtins.mapAttrs (_name: spec: nodes.${flakeLock.resolveInput lock spec}.result) (
            node.inputs or { }
          );
          outputs = (import (outPath + "/flake.nix")).outputs (inputs // { self = result; });
          result =
            if node.flake or true then
              outputs
              // sourceInfo
              // {
                inherit
                  outPath
                  inputs
                  outputs
                  sourceInfo
                  ;
                _type = "flake";
              }
            else
              sourceInfo // { inherit outPath sourceInfo; };
        in
        {
          inherit result sourceInfo;
        }
      ) (builtins.removeAttrs lock.nodes [ lock.root ]);
      # A source is the input itself with `pin` beside its outputs; the
      # identity comes from the lock and the fetched tree.
      sourceOf =
        _name: descriptor:
        nodes.${descriptor.node}.result
        // {
          pin = {
            system = "flake";
            files = flakeFiles;
            inherit dir;
          }
          // identity (descriptor.locked // nodes.${descriptor.node}.sourceInfo)
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
      mkRoot fetched.outPath (!clean) (
        if clean then fetched else builtins.removeAttrs fetched [ "rev" "shortRev" ]
      )
    else
      mkRoot dir false { };

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
