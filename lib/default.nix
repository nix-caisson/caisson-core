# SPDX-License-Identifier: MIT
#
# caisson-core, composed from its own entries.
#
# `compose` below is the one primitive: keyed overlay composition with
# identity, replacement and deterministic order, over plain builtins.
# Everything else caisson-core exports is an ordinary library overlay
# under lib-overlays/<name>/default.nix, composed here over the empty
# seed into the `caisson-core` namespace. mkLib composes the same
# entries into every consumer's library, so `import caisson-core` and
# `caisson-core` inside a composed library are one definition, and
# each part is a registered entry (`caisson-core/<name>`), replaceable
# by a same-key entry like any other.
#
# An entry is an attribute set:
#
#   {
#     key ? null;      # stable identity: a string, or null for anonymous
#     imports ? [ ];   # entries this entry depends on (keyed entries only)
#     overlay;         # final: prev: { ... }
#   }
#
# Composition semantics:
#
#   - Keyed entries are collected by a depth-first, post-order walk of
#     the consumer's entry list: an entry's imports are walked before
#     the entry itself.  The first occurrence of a key fixes its
#     position; the last occurrence supplies its value (replacement).
#     A replacement's imports are still walked, so entries it
#     introduces join the composition, but at the walk's current end:
#     a replacement inherits the replaced entry's slot, and its
#     imports guarantee reachability, not precedence.
#   - A key already on the walk's own path is skipped, so cycles
#     terminate; members of a cycle get no mutual ordering guarantee.
#   - Anonymous (keyless) entries cannot be imported.  They are
#     collected in consumer-list order and applied after the entire
#     keyed world, stacking when listed repeatedly.
#   - Application is a classic overlay fold: `prev` is everything
#     accumulated so far, and references through `final` see the
#     finished fixpoint.
#   - An overlay's output attribute NAMES must not depend on `final`;
#     a fixpoint whose attribute names depend on itself diverges.
#
# This file and the overlays use builtins only, on purpose.  Nothing
# here may reference nixpkgs' library (or any other library).

let

  validateEntry =
    e:
    if !builtins.isAttrs e then
      throw "caisson-core: an entry must be an attribute set { key ? null, imports ? [ ], overlay }"
    else if !(e ? overlay) || !builtins.isFunction e.overlay then
      throw "caisson-core: entry.overlay must be a function (final: prev: { ... })"
    else if !builtins.isList (e.imports or [ ]) then
      throw "caisson-core: entry.imports must be a list of entries"
    else if (e.key or null) != null && !builtins.isString (e.key or null) then
      throw "caisson-core: entry.key must be a string or null"
    else
      e;

  # Depth-first, post-order walk producing:
  #   winners: key -> entry (last occurrence)
  #   order:   list of keys (first-occurrence order)
  #   tail:    list of anonymous entries (consumer-list order)
  walk =
    entries:
    let
      goEntry =
        state: stack: raw:
        let
          e = validateEntry raw;
          k = e.key or null;
          onPath = k != null && builtins.elem k stack;
          stack' = if k == null then stack else stack ++ [ k ];
          walkImport =
            s: rawImport:
            let
              i = validateEntry rawImport;
            in
            if (i.key or null) == null then
              throw "caisson-core: a keyless entry cannot be imported; imports address stable identities, so give the entry a key"
            else
              goEntry s stack' i;
          afterImports = builtins.foldl' walkImport state (e.imports or [ ]);
        in
        if onPath then
          state
        else if k == null then
          afterImports // { tail = afterImports.tail ++ [ e ]; }
        else
          afterImports
          // {
            winners = afterImports.winners // {
              ${k} = e;
            };
            order =
              if builtins.hasAttr k afterImports.winners then afterImports.order else afterImports.order ++ [ k ];
          };
    in
    builtins.foldl' (s: e: goEntry s [ ] e) {
      winners = { };
      order = [ ];
      tail = [ ];
    } entries;

  fix =
    f:
    let
      x = f x;
    in
    x;

  extends =
    overlay: f: final:
    let
      prev = f final;
    in
    prev // overlay final prev;

  applyEntries = entryList: fix (builtins.foldl' (f: e: extends e.overlay f) (_final: { }) entryList);

  compose =
    { entries }:
    let
      walked = walk entries;
      keyedEntries = builtins.map (k: walked.winners.${k}) walked.order;
    in
    {
      lib = applyEntries (keyedEntries ++ walked.tail);
      meta = {
        inherit (walked) winners order;
        tailLength = builtins.length walked.tail;
      };
    };

  # The overlays caisson-core is made of, in composition order.
  names = [
    "compose"
    "resolve"
    "kernel"
    "lifecycle"
    "readers"
  ];

  # The keyed entries of caisson-core, bound to one composition: the
  # inputs the composition closes over and the entries it publishes
  # (the `nixpkgs-lib` entry, in a composition mkLib builds). Each
  # overlay file takes the closure
  # `{ closure-inputs, entries, compose, coreEntries, ... }` and
  # returns `{ imports ? [ ], overlay }`, the shape mkLibOverlay
  # produces; the closure is applied here by hand, since mkLibOverlay
  # is itself one of the things being composed.
  coreEntries =
    {
      inputs ? { },
      entries ? { },
    }:
    builtins.listToAttrs (
      builtins.map (
        name:
        let
          key = "caisson-core/${name}";
          applied = import (../lib-overlays + "/${name}") {
            closure-inputs = inputs;
            inherit entries compose coreEntries;
          };
        in
        {
          name = key;
          value = {
            inherit key;
            imports = applied.imports or [ ];
            overlay = applied.overlay;
          };
        }
      ) names
    );

in
(compose { entries = builtins.attrValues (coreEntries { }); }).lib.caisson-core
