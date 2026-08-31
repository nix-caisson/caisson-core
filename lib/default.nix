# SPDX-License-Identifier: MIT
#
# caisson-core: a minimal engine for composing library overlays.
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
# This file uses builtins only, on purpose.  Nothing here may
# reference nixpkgs' lib (or any other library).

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

  # Layered ecosystem-source resolution.  Never throws and never
  # formats a message: a full miss is the interpretable value null,
  # left to the caller to interpret.  Priority: the explicit argument,
  # then the client's declared defaults, then an input with exactly
  # the declared name.
  resolve =
    {
      name,
      explicit ? null,
      defaults ? { },
      inputs ? { },
    }:
    if explicit != null then
      explicit
    else if builtins.hasAttr name defaults then
      defaults.${name}
    else if builtins.hasAttr name inputs then
      inputs.${name}
    else
      null;

  # The kernel: minimal flake-output wiring over explicitly provided,
  # already-wired inputs (no lock handling, no fetching), and the
  # read-only-eval-safe partition extra-inputs loader.  Both files are
  # self-contained on purpose; see their headers.
  callFlake = import ./kernel/call-flake.nix;
  partitionExtraInputs = import ./kernel/partition-extra-inputs.nix;

  # The library lifecycle: mkLib and the registration machinery, built
  # on the engine above.  See its header for the contracts.
  lifecycle = import ./lifecycle.nix {
    inherit
      callFlake
      compose
      partitionExtraInputs
      resolve
      ;
  };

in
{
  inherit
    callFlake
    compose
    partitionExtraInputs
    resolve
    ;
  inherit (lifecycle)
    callConsumerFlake
    contributeModules
    importApply
    mkCoreOverlay
    mkExtendedLib
    mkLib
    ;
}
