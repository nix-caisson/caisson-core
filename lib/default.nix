# SPDX-License-Identifier: MIT
#
# caisson-core, composed from the entries it ships.
#
# `compose` below is the primitive: keyed overlay composition with
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
#     a replacement inherits the replaced entry's position, and its
#     imports guarantee reachability, not precedence.
#   - A key already on the walk's path is skipped, so cycles
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
# here may reference a library from outside this tree.

let

  validateEntry =
    e:
    if !builtins.isAttrs e then
      builtins.throw "caisson-core: an entry must be an attribute set { key ? null, imports ? [ ], overlay }"
    else if !(e ? overlay) || !builtins.isFunction e.overlay then
      builtins.throw "caisson-core: entry.overlay must be a function (final: prev: { ... })"
    else if !builtins.isList (e.imports or [ ]) then
      builtins.throw "caisson-core: entry.imports must be a list of entries"
    else if (e.key or null) != null && !builtins.isString (e.key or null) then
      builtins.throw "caisson-core: entry.key must be a string or null"
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
              builtins.throw "caisson-core: a keyless entry cannot be imported; imports address stable identities, so give the entry a key"
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

  # The overlay fold, keeping each layer beside the lib: `layers` holds,
  # per entry in application order, the entry, the attrset its overlay
  # returned (`result`) and the accumulation it received (`prev`).
  # Each is the value the fold used, so a reader of `layers` sees what
  # the lib was built from, and nothing is evaluated twice. Every overlay receives the finished
  # lib as `final` and the accumulation so far as `prev`, exactly as a
  # fixpoint of `extends` would give it.
  applyEntries =
    entryList:
    let
      folded =
        builtins.foldl'
          (
            acc: e:
            let
              result = e.overlay lib acc.prev;
            in
            {
              prev = acc.prev // result;
              layers = acc.layers ++ [
                {
                  entry = e;
                  inherit result;
                  inherit (acc) prev;
                }
              ];
            }
          )
          {
            prev = { };
            layers = [ ];
          }
          entryList;
      lib = folded.prev;
    in
    {
      inherit lib;
      inherit (folded) layers;
    };

  compose =
    { entries }:
    let
      walked = walk entries;
      keyedEntries = builtins.map (k: walked.winners.${k}) walked.order;
      applied = applyEntries (keyedEntries ++ walked.tail);
    in
    {
      inherit (applied) lib layers;
      meta = {
        inherit (walked) winners order;
        tailLength = builtins.length walked.tail;
      };
    };

  # The overlays caisson-core is made of, in composition order.
  names = [
    "compose"
    "resolve"
    "lifecycle"
    "readers"
    "util"
  ];

  # The keyed entries of caisson-core, bound to a composition: the
  # pinned sources the composition closes over (its `closure-inputs`)
  # and the default source per ecosystem it declares. Each overlay
  # file takes the closure
  # `{ closure-inputs, defaultEcosystemSrc, compose, coreEntries, ... }` and
  # returns `{ imports ? [ ], overlay }`, the shape mkLibOverlay
  # produces; the closure is applied here by hand, since mkLibOverlay
  # is itself one of the things being composed.
  coreEntries =
    {
      sources ? { },
      # The default source per ecosystem the composition declares.
      defaultEcosystemSrc ? { },
    }:
    builtins.listToAttrs (
      builtins.map (
        name:
        let
          key = "caisson-core/${name}";
          file = ../lib-overlays + "/${name}";
          applied = builtins.import file {
            closure-inputs = sources;
            inherit
              compose
              coreEntries
              defaultEcosystemSrc
              ;
          };
        in
        {
          name = key;
          value = {
            inherit key;
            imports = applied.imports or [ ];
            overlay = applied.overlay;
            origin = builtins.toString file;
          };
        }
      ) names
    );

in
(compose { entries = builtins.attrValues (coreEntries { }); }).lib.caisson-core
