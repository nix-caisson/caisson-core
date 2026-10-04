# SPDX-License-Identifier: MIT
#
# The library lifecycle: building a composed library from registered
# overlays and modules over the empty seed, with the `caisson-core`
# namespace (machinery, registries, manifest) composed into the result
# from caisson-core's entries. mkLib is the entry point.
#
# Contracts, shared with `compose`:
#
#   - Nothing is composed over: every function a library holds
#     arrives as an entry, nixpkgs' library included (the published
#     `nixpkgs-lib` entry, composed as upstream fixes it).
#   - The source of that entry is the tree's declared
#     `defaultEcosystemSrc.nixpkgs-lib` or `.nixpkgs`, or a pinned
#     source named exactly so, through `resolve`; a miss is null, and
#     the entry names the declaration only where it is composed.
#   - The `caisson-core` namespace is contributed by caisson-core's
#     entries and nothing else.  The manifest (the capture of what
#     mkLib consumed) enters through composition as a synthetic final
#     overlay, the same channel as everything else.
#
# This overlay takes the bootstrap closure of caisson-core's
# entries: the pinned sources this composition closes over, the entries it
# publishes (`nixpkgs-lib`, in a composition mkLib builds), `compose`
# and `coreEntries`, the function that makes these entries for a
# composition. It uses builtins only, on purpose.
{
  closure-inputs,
  entries,
  compose,
  coreEntries,
  ...
}:
let

  # Compose registered overlays into a library. The seed is the empty
  # attribute set: nothing is composed over, and everything a library
  # holds arrives as an entry. A keyed overlay keeps its key, so
  # `compose` deduplicates it and a same-key overlay registered later
  # replaces it; a keyless overlay joins the tail in list order.
  # Keyless imports are flattened in front of their importer; keyed
  # imports stay imports, which `compose` walks.
  #
  # `published` maps a key to the entry the composing tree holds under
  # it. An import addresses a stable identity, so an overlay built in
  # another tree that imports that tree's `nixpkgs-lib` entry gets
  # this tree's when composed here: every keyed entry or import whose
  # key is published is read from the map, not from the value the
  # importer carried.
  composeRegistered =
    {
      published ? { },
    }:
    let
      isKeyed = overlay: (overlay.key or null) != null;
      byKey =
        overlay:
        if isKeyed overlay && published ? ${overlay.key} then published.${overlay.key} else overlay;
      checkShape =
        overlay:
        if (builtins.isAttrs overlay) && (builtins.hasAttr "overlay" overlay) then
          overlay
        else
          throw ''
            Library overlays are `{ imports, overlay }` attrsets (build them
            with mkLibOverlay, or use another flake's exported overlays), but
            composition encountered a ${builtins.typeOf overlay}.
          '';
      # A keyed overlay's imports stay imports, which `compose` walks
      # before the importer; a keyless import among them gets a stable
      # synthetic key derived from the importer key, so it keeps that
      # position rather than falling into the keyless tail.
      keyedImports =
        key: imports:
        builtins.genList (
          i:
          let
            raw = checkShape (builtins.elemAt imports i);
          in
          if isKeyed raw then
            byKey raw
          else
            let
              synthetic = "${key}/imports/${toString i}";
            in
            raw
            // {
              key = synthetic;
              imports = keyedImports synthetic (raw.imports or [ ]);
            }
        ) (builtins.length imports);
      flattenOverlay =
        raw:
        let
          overlay = byKey (checkShape raw);
          imports = overlay.imports or [ ];
        in
        if isKeyed overlay then
          [
            {
              inherit (overlay) key;
              imports = keyedImports overlay.key imports;
              overlay = overlay.overlay;
            }
          ]
        else
          let
            keyless = builtins.filter (i: !(isKeyed i)) imports;
            keyed = builtins.map byKey (builtins.filter isKeyed imports);
          in
          (builtins.concatMap flattenOverlay keyless)
          ++ [
            {
              key = null;
              imports = keyed;
              overlay = overlay.overlay;
            }
          ];
    in
    # The whole `compose` result: the lib, and `meta` with the keyed
    # order, which is computed from keys and imports alone, so reading
    # it applies no overlay.
    overlays: compose { entries = builtins.concatMap flattenOverlay overlays; };

  mkExtendedLib = overlays: (composeRegistered { } overlays).lib;

  # The entry that brings nixpkgs' library into a composition: the
  # functions of the source supplying the `nixpkgs-lib` part of the
  # stack, as that source fixes them. (nixpkgs' lib/default.nix builds
  # its fixpoint with a bootstrap makeExtensible that exposes `extend`
  # only, no `__unfix__`, so the library cannot be re-tied over the
  # composed fixpoint here; a polyfill composed later overrides a
  # name for readers of the composed lib, not for upstream's
  # internal references.) `src` is a tree holding nixpkgs' `lib`
  # directory, either a nixpkgs checkout or the nixpkgs.lib mirror, or
  # that directory itself; null means no source was declared, and the
  # entry then fails where it is composed, naming the declaration.
  # Published under the key `nixpkgs-lib`: an overlay that needs
  # upstream's functions imports it, and a same-key entry replaces it.
  mkNixpkgsLibEntry = src: {
    key = "nixpkgs-lib";
    imports = [ ];
    overlay =
      _final: prev:
      let
        root =
          if src == null then
            throw ''
              caisson-core: the `nixpkgs-lib` entry has no source. Declare
              `defaultEcosystemSrc.nixpkgs-lib` (the nixpkgs.lib mirror, or nixpkgs'
              `lib` directory) or `defaultEcosystemSrc.nixpkgs` (a nixpkgs checkout)
              in the mkLib call, or pin a source named exactly `nixpkgs-lib` or
              `nixpkgs` in the `sources` passed to mkLib.
            ''
          else
            "${src}";
        libDir = if builtins.pathExists "${root}/lib/default.nix" then "${root}/lib" else root;
      in
      prev // import libDir;
  };

  # Build a composition-bound mkLibOverlay: everything passed to it
  # takes the closure attrset,
  # `{ closure-inputs, closure-lib, mkLibOverlay, ... }:`, as its
  # first arg list, and returns an `{ imports ? [ ], overlay }`
  # attrset.  Already-built overlays (e.g. another flake's exported
  # libOverlays) are registered directly rather than wrapped.
  mkLibOverlayFor =
    {
      sources,
      # Extra attrs merged into the closure applied to overlay files;
      # the composed fixpoint (closure-lib, so an overlay's functions
      # reach the registry of the composition that registered them),
      # the composition's mkModule and the static contribute helpers
      # arrive through here so overlays can contribute modules and
      # classes closed over their flake. Bound lazily: an overlay
      # reads them inside `overlay = final: prev:` or inside a
      # function it defines, never while it is being registered.
      extraOverlayClosure ? { },
    }:
    let
      mkLibOverlay =
        freeformOverlay:
        (
          let
            requiresImport = (builtins.isPath freeformOverlay) || (builtins.isString freeformOverlay);
            provenance =
              if requiresImport then
                "In lib overlay imported from `${builtins.toString freeformOverlay}`.\n"
              else
                "";
            reified = if requiresImport then import freeformOverlay else freeformOverlay;
            applied =
              if builtins.isFunction reified then
                reified (
                  {
                    closure-inputs = sources;
                    inherit mkLibOverlay;
                  }
                  // extraOverlayClosure
                )
              else
                throw ''
                  ${provenance}mkLibOverlay expects a function taking the closure attrset
                  (`{ closure-inputs, closure-lib, mkLibOverlay, ... }:`) as its first arg
                  list, but got a ${builtins.typeOf reified}. Register already-built overlays
                  directly instead of wrapping them in mkLibOverlay.
                '';
          in
          if (builtins.isAttrs applied) && (builtins.hasAttr "overlay" applied) then
            {
              imports = applied.imports or [ ];
              overlay = applied.overlay;
            }
            # The file the entry was built from, recorded as its origin
            # in the manifest's history; an entry built from a function
            # has none.
            // (if requiresImport then { origin = builtins.toString freeformOverlay; } else { })
          else
            throw ''
              ${provenance}After the closure arg list, a lib overlay is an
              `{ imports ? [ ], overlay }` attrset: put the `final: prev:` function
              under `overlay`, and any overlays it depends on under `imports`. Got
              a ${builtins.typeOf applied} instead.
            ''
        );
    in
    mkLibOverlay;

  # Build a composition-bound mkPkgOverlay, the package overlay
  # constructor: everything passed to it takes the closure attrset
  # `{ closure-inputs, closure-lib, mkPkgOverlay, ... }:` as its first
  # arg list and returns `{ imports ? [ ], overlay }`, the lib overlay
  # entry's shape, with `overlay = final: prev: ...` a nixpkgs overlay.
  # An entry built from a file records the file as its `origin`, the
  # identity the selection compares when a key is reached twice; an
  # entry built from a function has none. An entry imports a sibling
  # by reading it from the registry of the composition that registered
  # it, `closure-lib.caisson-core.libManifest.pkgOverlays.<name>`,
  # where it already carries its key. Already-built entries (another
  # flake's exported pkgOverlays) arrive through `projects`.
  mkPkgOverlayFor =
    {
      sources,
      # The composed fixpoint, bound lazily.
      finalLib,
    }:
    let
      mkPkgOverlay =
        freeformOverlay:
        let
          requiresImport = (builtins.isPath freeformOverlay) || (builtins.isString freeformOverlay);
          provenance =
            if requiresImport then
              "In package overlay imported from `${builtins.toString freeformOverlay}`.\n"
            else
              "";
          reified = if requiresImport then import freeformOverlay else freeformOverlay;
          applied =
            if builtins.isFunction reified then
              reified {
                closure-inputs = sources;
                closure-lib = finalLib;
                inherit mkPkgOverlay;
              }
            else
              throw ''
                ${provenance}mkPkgOverlay expects a function taking the closure attrset
                (`{ closure-inputs, closure-lib, mkPkgOverlay, ... }:`) as its first arg
                list, but got a ${builtins.typeOf reified}. Register already-built package
                overlays through `projects` instead of wrapping them in mkPkgOverlay.
              '';
        in
        if
          (builtins.isAttrs applied)
          && (builtins.hasAttr "overlay" applied)
          && builtins.isFunction applied.overlay
        then
          {
            imports = applied.imports or [ ];
            overlay = applied.overlay;
            origin = if requiresImport then builtins.toString freeformOverlay else null;
          }
        else
          throw ''
            ${provenance}After the closure arg list, a package overlay is an
            `{ imports ? [ ], overlay }` attrset: put the nixpkgs overlay
            (`final: prev:`) under `overlay`, and the package overlays it depends
            on under `imports`. Got a ${builtins.typeOf applied} instead.
          '';
    in
    mkPkgOverlay;

  # Key an entry and its imports for a registry. `keyOf` maps the key an
  # entry carried to the key it has here; an import without a key gets
  # a synthetic key derived from its importer's key and its position,
  # so it keeps that position without claiming a name.
  rekeyPkgOverlay =
    keyOf: key: entry:
    entry
    // {
      inherit key;
      imports = builtins.genList (
        i:
        let
          raw = builtins.elemAt (entry.imports or [ ]) i;
          carried = raw.key or null;
        in
        rekeyPkgOverlay keyOf (if carried == null then "${key}#import-${toString i}" else keyOf carried) raw
      ) (builtins.length (entry.imports or [ ]));
    };

  # The package overlays a selection applies, in order: each selected
  # entry after the entries it imports, walked depth first, and each key
  # once, where its first occurrence falls. One key reached through two
  # paths is one entry when both carry the same origin (or either carries
  # none, an entry built from a function); two different entries under
  # one key are refused rather than either silently winning. The result is
  # the list of nixpkgs overlays to hand a package set, in that order.
  pkgOverlaysFor =
    selection:
    let
      check =
        e:
        if !builtins.isAttrs e || !builtins.isFunction (e.overlay or null) then
          throw "caisson-core.pkgOverlaysFor: a package overlay is an `{ key, imports ? [ ], overlay }` attrset whose `overlay` is a function (final: prev: { ... }); select entries from a registry (`libManifest.pkgOverlays`)"
        else if !builtins.isString (e.key or null) then
          throw "caisson-core.pkgOverlaysFor: a selected package overlay has no key; select entries from a registry (`libManifest.pkgOverlays`), where every entry carries its registry name"
        else
          e;
      go =
        state: stack: raw:
        let
          e = check raw;
          k = e.key;
          prior = state.seen.${k};
          origin = e.origin or null;
          priorOrigin = prior.origin or null;
          afterImports = builtins.foldl' (s: i: go s (stack ++ [ k ]) i) state (e.imports or [ ]);
        in
        if builtins.elem k stack then
          state
        else if state.seen ? ${k} then
          if origin != null && priorOrigin != null && origin != priorOrigin then
            throw ''
              caisson-core: two different package overlays are registered under the
              key `${k}`, from `${priorOrigin}` and from `${origin}`. One key names one
              entry: give one of them another name, or select one of them.
            ''
          else
            state
        else if afterImports.seen ? ${k} then
          afterImports
        else
          afterImports
          // {
            seen = afterImports.seen // {
              ${k} = e;
            };
            order = afterImports.order ++ [ e.overlay ];
          };
    in
    if !builtins.isList selection then
      throw "caisson-core.pkgOverlaysFor expects a list of package overlay entries (e.g. `[ registry.default ]`), but got a ${builtins.typeOf selection}."
    else
      (builtins.foldl' (s: e: go s [ ] e) {
        seen = { };
        order = [ ];
      } selection).order;

  moduleMap =
    f: module:
    (
      let
        requiresImport = (builtins.isPath module) || (builtins.isString module);
        reifiedModule = (if requiresImport then import module else module);
        applied = (
          if
            (
              (builtins.isAttrs reifiedModule)
              && (builtins.hasAttr "_file" reifiedModule)
              && (builtins.hasAttr "imports" reifiedModule)
              && (builtins.isList reifiedModule.imports)
              && ((builtins.length reifiedModule.imports) == 1)
            )
          then
            {
              _file = reifiedModule._file;
              imports = builtins.map (m: moduleMap f m) reifiedModule.imports;
            }
          else
            f reifiedModule
        );
      in
      (
        if requiresImport then
          {
            _file = module;
            imports = [ applied ];
          }
        else
          applied
      )
    );

  importApply = module: staticArgs: moduleMap (m: m staticArgs) module;

  # Merge module contributions into the registry from inside an
  # overlay body: `overlay = final: prev: contributeModules prev
  # { <class>.<name> = mkModule "<class>" ./m.nix; } // { ... }`.
  # Static on purpose: an overlay's output attribute names must not
  # depend on `final`, so the helper arrives through the overlay
  # closure rather than the composed library.
  contributeModules =
    prev: contributions:
    let
      prevModules = (prev.caisson-core or { }).modules or { };
    in
    {
      caisson-core = (prev.caisson-core or { }) // {
        modules =
          prevModules
          // builtins.mapAttrs (class: names: (prevModules.${class} or { }) // names) contributions;
      };
    };

  # Declare module classes from inside an overlay body, the way
  # contributeModules contributes modules: `overlay = final: prev:
  # contributeClasses prev { nixos = { integration = "nixos"; mkModule
  # = final.caisson-core.mkModule "nixos"; }; } // { ... }`. The class
  # index (`caisson-core.classes.<class>`) names, per class, the
  # integration that owns it and the mkModule every reader registers
  # that class through; a same-key declaration composed later
  # replaces it, which is how an integration wrapping another takes
  # over the class. Static like contributeModules, for the same
  # reason.
  contributeClasses =
    prev: declarations:
    let
      prevClasses = (prev.caisson-core or { }).classes or { };
    in
    {
      caisson-core = (prev.caisson-core or { }) // {
        classes = prevClasses // declarations;
      };
    };

  # Find the manifest in whatever a file returns: a manifest itself,
  # an attrset carrying `caisson.manifest`, an evaluated configuration
  # carrying `config.caisson.manifest`, or a lib (or a package set,
  # through `pkgs.lib`) carrying the phase manifests, where the last
  # manifest filled in is the manifest.  Null when the value carries none.
  manifestOf =
    value:
    let
      isManifest = v: builtins.isAttrs v && (v._type or null) == "caisson-manifest";
      # The last filled in of a composed lib's phase manifests, or null.
      lastFilled =
        composed:
        let
          phases = composed.caisson-core;
        in
        if phases.evalManifest or null != null then
          phases.evalManifest
        else if phases.pkgsManifest or null != null then
          phases.pkgsManifest
        else
          phases.libManifest or null;
      candidates = [
        value
        (value.caisson.manifest or null)
        (value.config.caisson.manifest or null)
        (if builtins.isAttrs value && value ? caisson-core then lastFilled value else null)
        (if builtins.isAttrs value && value ? lib.caisson-core then lastFilled value.lib else null)
      ];
      found = builtins.filter isManifest candidates;
    in
    if found == [ ] then null else builtins.head found;

  # Finalize a child configuration. What an integration's
  # `mkConfiguration` returns is a function `{ name, parent }:
  # <manifest>`, since a configuration learns its name and its parent
  # from where it is declared; the parent calls it with the name the
  # child is declared under and its childless manifest. The
  # function's pattern must name exactly `name` and `parent`, which
  # `builtins.functionArgs` reads, so anything else declared where a
  # configuration belongs is refused there. `what` names the
  # declaration in the messages. The result must be a manifest, or,
  # for a configuration evaluated at a system, its evaluations: an
  # attribute set of manifests by system, empty where no system is in
  # force.
  finalizeChild =
    {
      name,
      parent,
      what ? "`${name}`",
    }:
    child:
    let
      expected = {
        name = false;
        parent = false;
      };
    in
    if !(builtins.isFunction child && builtins.functionArgs child == expected) then
      throw ''
        ${what} is declared with ${
          if builtins.isFunction child then
            "a function that does not take exactly `{ name, parent }`"
          else
            "a ${builtins.typeOf child}"
        }, where a configuration is expected: a function of
        `{ name, parent }` returning a manifest, as an integration's
        `mkConfiguration` builds it (for a package config,
        `lib.caisson.nixpkgs.mkConfiguration`).
      ''
    else
      let
        result = child { inherit name parent; };
      in
      if isManifest result || isEvaluations result then
        result
      else
        throw "The configuration ${what} did not return a manifest, or manifests by system.";

  isManifest = value: builtins.isAttrs value && (value._type or null) == "caisson-manifest";

  # The evaluations of a configuration evaluated at a system: manifests
  # by system.
  isEvaluations =
    value:
    builtins.isAttrs value && !(value ? _type) && builtins.all isManifest (builtins.attrValues value);

  # The system above a configuration evaluated at that system, beneath
  # `parent`, holding `children`, by integration and then name.
  systemNode =
    {
      parent,
      system,
      childless,
      children,
    }:
    builtins.intersectAttrs inheritedFields parent
    // {
      _type = "caisson-manifest";
      type = "system";
      name = system;
      inherit
        system
        parent
        childless
        children
        ;
      ancestors = (parent.ancestors or [ ]) ++ [ parent ];
      nearest =
        (parent.nearest or { })
        // (if (parent.type or "lib") == "lib" then { } else { ${parent.type} = parent; });
      inputs = builtins.concatMap builtins.attrValues (builtins.attrValues children);
    };

  # The record fields a module evaluation reads from its parent: the
  # declared facts and the registries, which are views over the chain.
  inheritedFields = {
    configs = null;
    defaultEcosystemSrc = null;
    libOverlays = null;
    moduleProjects = null;
    modules = null;
    pkgOverlays = null;
    pkgSets = null;
    projects = null;
    root = null;
    sources = null;
    systems = null;
  };

  # The fields `mkConfiguration` writes, which an integration's `record`
  # may not name.
  configurationFields = [
    "_type"
    "ancestors"
    "childless"
    "childlessManifest"
    "children"
    "inputs"
    "name"
    "nearest"
    "outputs"
    "parent"
    "system"
    "type"
    "value"
  ];

  # A module evaluation as a configuration: the function of
  # `{ name, parent }` an integration's constructor returns, which
  # builds the evaluation's manifest once its name and its parent are
  # known. `final` is the lib the constructor lives in, the lib the
  # configuration is declared under.
  #
  # `type` is the integration's name. `evaluate` performs the
  # evaluator's call: it takes `{ lib, manifest }`, the lib the
  # evaluation runs on and the manifest being built, and returns
  # `value` (the evaluation as the evaluator returned it), `outputs`
  # (the integration's references into the value) and `children` (the
  # finalized configurations declared beneath, by integration and then
  # name). `record` is plain data the integration adds to the manifest.
  #
  # The evaluation has a childless view and a full view. Each is a
  # manifest, and each runs on the lib of the declaration rebuilt
  # with that manifest as `evalManifest`. The childless view is the
  # evaluation without the configurations declared beneath it, and it
  # is what those configurations are finalized against: the full
  # manifest carries it as `childlessManifest`, and `evaluate` hands it
  # to `finalizeChild` as the parent of each child. The full view is
  # the manifest returned, and its `children` are read from the full
  # evaluation alone. Nothing forces the childless evaluation until a
  # child, or a reader of `childlessManifest`, reads its value, so a
  # configuration with no children is evaluated once.
  #
  # With `perSystem`, the integration evaluates a configuration at a
  # system, and a declared configuration is an evaluation for every
  # system in force where it is declared: the function returns those
  # evaluations by system, as many as there are systems in force and
  # none where there are none. In the tree the system sits above the
  # name. Each evaluation is a manifest as above, under the name it is
  # declared by, with its system as `system`, and its parent is the
  # system: a manifest of type `system`, named by the system, beneath
  # the parent that declares the configuration. The configuration sees
  # that system without what is declared under it. The parent's full
  # manifest holds each system under `children.system`, with the
  # evaluations declared at it by integration and then name, beside
  # the configurations that are evaluated once for every system,
  # which stay under `children.<integration>`. The systems in force
  # carry on beneath an evaluation, so a configuration declared
  # beneath it has a system above it in turn.
  mkConfigurationFor =
    final:
    {
      type,
      evaluate,
      record ? { },
      perSystem ? false,
    }:
    { name, parent }:
    let
      owned = builtins.filter (field: record ? ${field}) configurationFields;
      checkedRecord =
        if owned == [ ] then
          record
        else
          throw ''
            caisson-core.mkConfiguration: the `${type}` integration's `record` names
            `${builtins.head owned}`, a field mkConfiguration writes.
          '';
      libManifest = final.caisson-core.libManifest;

      # The fields of a manifest of this integration declared under
      # `name` beneath `parent`.
      baseUnder =
        parent:
        builtins.intersectAttrs inheritedFields parent
        // checkedRecord
        // {
          _type = "caisson-manifest";
          inherit type parent;
          ancestors = (parent.ancestors or [ ]) ++ [ parent ];
          # The nearest ancestor of each integration. A lib is the root
          # of the chain and no integration, so it is not among them.
          nearest =
            (parent.nearest or { })
            // (if (parent.type or "lib") == "lib" then { } else { ${parent.type} = parent; });
        }
        // (if name == null then { } else { inherit name; });

      # The configurations an evaluation declares, as its manifest
      # holds them: those evaluated once under their integration, and
      # the evaluations of those evaluated at a system under that
      # system.
      childrenOf =
        childlessManifest: declared:
        let
          select =
            keep:
            let
              kept = builtins.mapAttrs (
                _: byName:
                builtins.listToAttrs (
                  builtins.concatMap (
                    child:
                    let
                      value = keep byName.${child};
                    in
                    if value == null then
                      [ ]
                    else
                      [
                        {
                          name = child;
                          inherit value;
                        }
                      ]
                  ) (builtins.attrNames byName)
                )
              ) declared;
            in
            builtins.removeAttrs kept (
              builtins.filter (integration: kept.${integration} == { }) (builtins.attrNames kept)
            );
          direct = select (finalized: if isManifest finalized then finalized else null);
          systems = builtins.attrNames (
            builtins.foldl' (
              seen: byName:
              builtins.foldl' (
                seen: finalized: if isManifest finalized then seen else seen // finalized
              ) seen (builtins.attrValues byName)
            ) { } (builtins.attrValues declared)
          );
          bySystem = builtins.listToAttrs (
            builtins.map (system: {
              name = system;
              value = systemNode {
                parent = childlessManifest;
                inherit system;
                childless = false;
                children = select (
                  finalized: if isManifest finalized then null else finalized.${system} or null
                );
              };
            }) systems
          );
        in
        direct // (if systems == [ ] then { } else { system = bySystem; });

      # An evaluation on `base`: its full manifest, which carries the
      # childless manifest.
      evaluation =
        base:
        let
          view =
            childless:
            let
              evaluated = evaluate {
                lib = final.caisson-core.withManifests { evalManifest = manifest; };
                inherit manifest;
              };
              children = if childless then { } else childrenOf childlessManifest (evaluated.children or { });
              manifest =
                base
                // {
                  inherit childless children;
                  value = evaluated.value;
                  outputs = evaluated.outputs or { };
                  inputs =
                    [ libManifest ]
                    ++ (
                      if childless then
                        [ ]
                      else
                        [ childlessManifest ] ++ builtins.concatMap builtins.attrValues (builtins.attrValues children)
                    );
                }
                // (if childless then { } else { inherit childlessManifest; });
            in
            manifest;
          childlessManifest = view true;
        in
        view false;

      # The evaluations of a configuration evaluated at a system: for
      # every system in force where it is declared, the evaluation
      # beneath that system.
      systems = if (parent.systems or null) == null then [ ] else parent.systems;
      evaluations = builtins.listToAttrs (
        builtins.map (system: {
          name = system;
          value = evaluation (
            baseUnder (systemNode {
              inherit parent system;
              childless = true;
              children = { };
            })
            // {
              inherit system;
            }
          );
        }) systems
      );
    in
    if perSystem then evaluations else evaluation (baseUnder parent);

  # The segments needed to tell the things in a tree apart, from the
  # path of each. A path is the list of `{ type, name }` segments from
  # the top down to the thing, whose last segment is the name of the
  # thing. The result has, for each path in order, the segments kept,
  # as strings, in path order. How kept segments are written out as a
  # published name is for whoever publishes them.
  #
  # The rule keeps the last segment of every path, and beyond it only
  # the segments where paths that end in the same name fork. Among the
  # paths that end in a name, it drops the prefix they share, keeps the
  # segment at which they first differ, and does the same within each
  # branch. So a name that is alone stays bare, and names that collide
  # gain the segments that tell them apart. A segment is kept as its
  # name, or as `type/name` where the branches of that fork hold the
  # same name under several types. Paths that are equal are left
  # equal: whoever publishes them reports the clash.
  elide =
    paths:
    let
      indices = builtins.genList (i: i) (builtins.length paths);
      pathAt = i: builtins.elemAt paths i;
      last = path: builtins.length path - 1;
      leafOf = i: (builtins.elemAt (pathAt i) (last (pathAt i))).name;
      groups = builtins.groupBy (i: if pathAt i == [ ] then "0" else "1${leafOf i}") indices;

      # The forks among `members`, paths that agree before `depth`:
      # for each member, the depths at which it forks from the rest.
      forks =
        members: depth:
        if builtins.length members <= 1 then
          [ ]
        else
          let
            segmentOf =
              i:
              let
                path = pathAt i;
              in
              if depth < last path then builtins.elemAt path depth else null;
            keyOf =
              i:
              let
                segment = segmentOf i;
              in
              if segment == null then "" else "${segment.type}/${segment.name}";
            branches = builtins.groupBy keyOf members;
            keys = builtins.attrNames branches;
            names = builtins.map (key: (segmentOf (builtins.head branches.${key})).name) (
              builtins.filter (key: key != "") keys
            );
            shared = name: builtins.length (builtins.filter (other: other == name) names) > 1;
          in
          if builtins.length keys == 1 then
            if keys == [ "" ] then [ ] else forks members (depth + 1)
          else
            builtins.concatMap (
              key:
              if key == "" then
                [ ]
              else
                let
                  branch = branches.${key};
                  segment = segmentOf (builtins.head branch);
                in
                builtins.map (i: {
                  index = i;
                  inherit depth;
                  qualified = shared segment.name;
                }) branch
                ++ forks branch (depth + 1)
            ) keys;

      kept = builtins.concatMap (key: forks groups.${key} 0) (builtins.attrNames groups);

      segmentsOf =
        i:
        let
          path = pathAt i;
          forksOfPath = builtins.filter (fork: fork.index == i) kept;
          render =
            depth:
            let
              segment = builtins.elemAt path depth;
              here = builtins.filter (fork: fork.depth == depth) forksOfPath;
            in
            if depth == last path then
              [ segment.name ]
            else if here == [ ] then
              [ ]
            else if (builtins.head here).qualified then
              [ "${segment.type}/${segment.name}" ]
            else
              [ segment.name ];
        in
        builtins.concatMap render (builtins.genList (depth: depth) (builtins.length path));
    in
    builtins.map segmentsOf indices;

  # Finalize the configuration a top ends with: a top has no parent
  # that declares it under an attribute, so it takes the name the
  # composition declares on mkLib, none when the composition declares
  # none, and the lib's manifest as its parent.
  finalizeTopFor =
    final: configuration:
    let
      libManifest = final.caisson-core.libManifest;
    in
    if libManifest == null then
      throw ''
        caisson-core.finalizeTop finalizes a configuration under a
        composition's manifest, but this library carries none at
        `caisson-core.libManifest`. Compose the library with
        caisson-core.mkLib, which captures a manifest.
      ''
    else
      finalizeChild {
        name = libManifest.name or null;
        parent = libManifest;
        what = "The top configuration";
      } configuration;

  # The layers that define a name, from a manifest's history: given a
  # manifest and an attribute path (`[ "my-project" "helper" ]`), the
  # layer events whose layer defines that path, in composition order,
  # so the last is the winner and the rest are shadowed. A layer that
  # returns `prev.x // { ... }` carries the names already under `x`
  # without defining them: a name counts as carried when it has the
  # same binding position in what the layer returned and in what it
  # received, or, with no position on either side, an equal value.
  # Each carries
  # the event's key, index and origin, the value the path had after
  # that layer, and where the layer binds the name, from
  # `unsafeGetAttrPos`. A position is kept only when it lies within
  # the layer's origin file; a name a layer computes rather than
  # writes has no position there, or a position inside the library
  # that computed it, and is reported with the layer's file alone.
  definers =
    manifest: path:
    let
      has =
        set: p:
        p == [ ]
        || (
          builtins.isAttrs set && set ? ${builtins.head p} && has set.${builtins.head p} (builtins.tail p)
        );
      get = set: p: builtins.foldl' (acc: k: acc.${k}) set p;
      depth = builtins.length path;
      last = builtins.elemAt path (depth - 1);
      parentPath = builtins.genList (i: builtins.elemAt path i) (depth - 1);
      within =
        file: position:
        position != null
        && file != null
        && (
          position.file == file
          || builtins.substring 0 (builtins.stringLength file + 1) position.file == file + "/"
        );
      positionIn = set: builtins.unsafeGetAttrPos last (get set parentPath);
      carried =
        event:
        has event.prev path
        && (
          let
            returned = positionIn event.result;
            received = positionIn event.prev;
            equal = builtins.tryEval (get event.result path == get event.prev path);
          in
          if returned != null || received != null then
            returned == received
          else
            equal.success && equal.value
        );
    in
    builtins.concatMap (
      event:
      if event.operation == "layer" && has event.result path && !(carried event) then
        let
          position = positionIn event.result;
        in
        [
          {
            inherit (event) key index origin;
            value = get event.result path;
            position = if within event.origin.file position then position else null;
          }
        ]
      else
        [ ]
    ) manifest.history;

  # Build a composition-bound, class-parameterized mkModule.
  # `finalLib` is the composed fixpoint (for closure-lib), bound
  # lazily; a module reaches the registry of the composition that
  # registered it through closure-lib, under
  # `caisson-core.modules.<class>`.
  mkModuleForComposition =
    {
      sources,
      finalLib,
    }:
    let
      mkModuleClass =
        moduleClass:
        let
          mkModule = mkModuleClass moduleClass;
          closureArgs = {
            inherit mkModule;
            closure-inputs = sources;
            closure-lib = finalLib;
          };
        in
        freeformModule:
        (
          # Everything passed to mkModule takes the closure attrset as its first
          # arg list: `{ closure-inputs, closure-lib, mkModule, ... }: <module>`.
          let
            applyClosure =
              m:
              if builtins.isFunction m then
                m closureArgs
              else
                throw ''
                  mkModule (class `${moduleClass}`) expects a module function taking the
                  closure attrset (`{ closure-inputs, closure-lib, mkModule, ... }:`) as
                  its first arg list, but got a ${builtins.typeOf m}.
                '';
            requiresImport = (builtins.isPath freeformModule) || (builtins.isString freeformModule);
          in
          if requiresImport then
            # `key` mirrors the module system's identity for path imports: the
            # same file passed through mkModule at two sites deduplicates
            # the same way importing the same path twice would.
            {
              _file = freeformModule;
              key = builtins.toString freeformModule;
              imports = [ (applyClosure (import freeformModule)) ];
            }
          else
            moduleMap applyClosure freeformModule
        );
    in
    mkModuleClass;

  # mkLib's signature is its pattern, with no `...`: a missing or
  # unexpected argument is Nix's error at the call site, naming
  # mkLib and pointing here.
  mkLib =
    {
      # Replaces `inputs`; at a flake top: inherit (caisson-core.lib.caisson-core.pins.flake inputs) sources root;
      #
      # The tree's pinned sources, as a pin reader returns them. A
      # flakeless top reads its pins with pins.flake-compat or
      # pins.npins and supplies `root` itself (pins.gitRoot). The
      # composition's overlays and modules close over these as
      # `closure-inputs`; a composition that pins nothing passes
      # `sources = { };`.
      sources,
      # The identity of the tree being built, as pins.flake or
      # pins.gitRoot returns it; null for a composition that is not a
      # top, a library composed inside a test or a check.
      root ? null,
      # The project's name, e.g. "my-project": the name of the
      # parentless configuration and the namespace its overlays
      # contribute to the composed library.
      name ? null,
      # The platforms the tree builds on.
      systems ? null,
      # The tree's default source per ecosystem, by exact name (the
      # argument once called `ecosystems`).
      defaultEcosystemSrc ? null,
      # Consumed projects' contributions, by project name.
      projects ? null,
      # `lib: { <class>.<name> = module; }`, usually mkModules ./modules.
      modules ? null,
      # `lib: { <class>.<name> = configuration; }`, usually mkModules ./configs.
      configs ? null,
      # `mkLibOverlay: { <name> = overlay; }`, usually mkLibOverlays ./lib-overlays.
      libOverlays ? null,
      # `lib: [ <entry> ]`: which registered overlays apply to this
      # composition, given the core lib, which carries the registry as
      # `lib.caisson-core.nixpkgs-lib.overlays.<name>`.
      libOverlayImports ? null,
      # `mkPkgOverlay: { <name> = entry; }`, usually mkPkgOverlays ./pkg-overlays:
      # the package overlays this tree registers, keyed entries whose
      # `overlay` is a nixpkgs overlay. Nothing here applies them; a
      # package set selects from the registry through pkgOverlaysFor.
      pkgOverlays ? null,
      # `lib: { <name> = <package config evaluation>; }`, given the
      # bootstrap lib: the package configs this tree declares, by config
      # name, each the evaluation an integration's constructor returns.
      # Nothing here interprets them; they are recorded in the full
      # manifest's `pkgSets`.
      pkgSets ? null,
    }@resolvedArgs:
    (
      let
        sources =
          if builtins.isAttrs resolvedArgs.sources then
            resolvedArgs.sources
          else
            throw ''
              mkLib expects `sources` to be an attribute set of pinned source trees keyed
              by name, as a pin reader returns it, but got a ${builtins.typeOf resolvedArgs.sources}.
            '';

        rawRoot = resolvedArgs.root or null;
        root =
          if rawRoot == null || (builtins.isAttrs rawRoot && rawRoot ? outPath) then
            rawRoot
          else
            throw ''
              mkLib expects `root` to be the identity of the tree being built, an
              attribute set with at least `outPath` (as pins.flake or pins.gitRoot
              returns it), or null for a composition that is not a top, but got a
              ${if builtins.isAttrs rawRoot then "set without outPath" else builtins.typeOf rawRoot}.
            '';

        # The sources as the record keeps them: a directory reader's pin
        # files are relative to the directory it read (`pin.dir`), and
        # the record states them relative to the root when the directory
        # lies inside the root's tree. A directory outside it, or a
        # composition with no root, keeps `pin.dir`. The root's path is
        # read only for a source with a `pin.dir`: at a flake top the
        # root's out path is `self.outPath`, which the flake's outputs
        # cannot read while they are being computed.
        recordedSources =
          let
            relativeTo =
              prefix: dir:
              let
                d = toString dir;
                n = builtins.stringLength prefix;
              in
              if d == prefix then
                ""
              else if builtins.substring 0 (n + 1) d == prefix + "/" then
                builtins.substring (n + 1) (builtins.stringLength d) d
              else
                null;
            record =
              source:
              let
                pin = source.pin or null;
                rel =
                  if pin == null || !(pin ? dir) || root == null then
                    null
                  else
                    relativeTo (toString root.outPath) pin.dir;
              in
              if rel == null then
                source
              else
                source
                // {
                  pin = builtins.removeAttrs pin [ "dir" ] // {
                    files = builtins.mapAttrs (_: file: if rel == "" then file else rel + "/" + file) pin.files;
                  };
                };
          in
          builtins.mapAttrs (_: record) sources;

        # An optional argument left out, or passed as null, takes its
        # default.
        given =
          name: default:
          let
            value = resolvedArgs.${name} or null;
          in
          if value == null then default else value;

        rawModules = given "modules" (_lib: { });
        rawConfigs = given "configs" (_lib: { });
        rawLibOverlays = given "libOverlays" (mkLibOverlay: { });
        rawPkgOverlays = given "pkgOverlays" (mkPkgOverlay: { });
        rawPkgSets = given "pkgSets" (_lib: { });
        rawLibOverlayImports = given "libOverlayImports" (
          lib: builtins.attrValues (builtins.removeAttrs lib.caisson-core.nixpkgs-lib.overlays publishedNames)
        );
        rawEcosystems = given "defaultEcosystemSrc" { };
        rawProjects = given "projects" { };
        rawSystems = resolvedArgs.systems or null;
        rawName = resolvedArgs.name or null;

        # The platforms the tree builds on, declared here and
        # read from the manifest by whatever needs a system list
        # before any evaluation names a host platform. Null when the
        # composition declares none.
        systems =
          if
            rawSystems == null || (builtins.isList rawSystems && builtins.all builtins.isString rawSystems)
          then
            rawSystems
          else
            throw ''
              mkLib expects `systems` to be a list of system strings (e.g.
              `[ "x86_64-linux" ]`), but got a ${builtins.typeOf rawSystems}.
            '';

        # The project's name: the name the tree holds for itself,
        # declared here and read from the manifest. A
        # configuration no parent declares takes it as its name, since
        # a name is otherwise the attribute a parent declares a child
        # under and a parentless evaluation has no such attribute, and
        # the project's overlays contribute to the composed library
        # under it. Null when the composition declares none, which
        # leaves such a configuration unnamed.
        name =
          if rawName == null || builtins.isString rawName then
            rawName
          else
            throw ''
              mkLib expects `name` to be the string naming the project, which is
              also the namespace it contributes to the composed library (e.g.
              `"my-project"`, read as `lib.my-project`), but got a ${builtins.typeOf rawName}.
            '';

        # Consumed projects: whole upstream contributions, registered
        # as units.  A project value is assumed to carry `libOverlays`
        # and class-keyed `modules` dictionaries, which a caisson-built
        # flake's outputs already do; the shape is assumed rather than
        # checked (producers validate their exports).  The
        # project's overlays join the registered dictionary and its
        # modules join the registry under `<project>/<name>`, so the
        # existing selections keep per-item choice: libOverlayImports
        # decides which overlays apply here, and the class registry's
        # selection at each use site decides which modules load.
        projects =
          if builtins.isAttrs rawProjects then
            rawProjects
          else
            throw ''
              mkLib expects `projects` to be an attribute set of consumed
              project contributions keyed by project name (e.g.
              `{ my-dep = inputs.my-dep; }`), but got a ${builtins.typeOf rawProjects}.
            '';

        prefixNames =
          projectName: attrs:
          builtins.listToAttrs (
            builtins.map (n: {
              name = "${projectName}/${n}";
              value = attrs.${n};
            }) (builtins.attrNames attrs)
          );

        # Each contributed lib overlay records the project it came from
        # in `project`, as a package overlay entry does.
        projectLibOverlays = builtins.foldl' (
          acc: projectName:
          acc
          // builtins.mapAttrs (_: overlay: overlay // { project = projectName; }) (
            prefixNames projectName (projects.${projectName}.libOverlays or { })
          )
        ) { } (builtins.attrNames projects);

        # Consumed projects' package overlays, under `<project>/<name>`
        # like their lib overlays. A project's entries and the entries
        # they import carry the keys of the project's registry; a key
        # without a `/` is one of the project's names and is keyed
        # `<project>/<key>` here, so an import of a sibling still meets
        # the sibling, and a key with a `/` names an entry the project
        # itself took from another project and keeps it, so two
        # projects importing the same third project's entry import one
        # entry. Each entry records the project that contributed it.
        projectPkgOverlays = builtins.foldl' (
          acc: projectName:
          let
            keyOf =
              key: if builtins.match ".*/.*" key != null then key else "${projectName}/${key}";
            contributed =
              entry:
              entry
              // {
                project = projectName;
                imports = builtins.map contributed (entry.imports or [ ]);
              };
          in
          acc
          // builtins.mapAttrs (
            prefixed: entry: contributed (rekeyPkgOverlay keyOf prefixed entry)
          ) (prefixNames projectName (projects.${projectName}.pkgOverlays or { }))
        ) { } (builtins.attrNames projects);

        projectModules = builtins.foldl' (
          acc: projectName:
          let
            classed = projects.${projectName}.modules or { };
          in
          acc
          // builtins.listToAttrs (
            builtins.map (class: {
              name = class;
              value = (acc.${class} or { }) // prefixNames projectName classed.${class};
            }) (builtins.attrNames classed)
          )
        ) { } (builtins.attrNames projects);

        # The project each contributed module came from, keyed like the
        # module registry (`<class>.<project>/<name>`). A module value is
        # a function, a path or an attrset, so the origin cannot ride on
        # it the way `project` rides on an overlay entry, and wrapping it
        # would change the module the registry and the exports hand out
        # (its key, its definition locations, what `disabledModules`
        # names); the origin sits beside the registry instead.
        projectModuleProjects = builtins.foldl' (
          acc: projectName:
          let
            classed = projects.${projectName}.modules or { };
          in
          acc
          // builtins.listToAttrs (
            builtins.map (class: {
              name = class;
              value =
                (acc.${class} or { })
                // builtins.mapAttrs (_: _: projectName) (prefixNames projectName classed.${class});
            }) (builtins.attrNames classed)
          )
        ) { } (builtins.attrNames projects);

        # Declared ecosystem sources: mkLib-time facts, captured in the
        # manifest for the layered resolution higher layers perform
        # (explicit argument, then these declarations, then the pinned
        # source with exactly the declared name). Nothing here
        # interprets them.
        defaultEcosystemSrc =
          if builtins.isAttrs rawEcosystems then
            rawEcosystems
          else
            throw ''
              mkLib expects `defaultEcosystemSrc` to be an attribute set of ecosystem
              sources keyed by their exact names (e.g. `{ nixpkgs = ...; }`),
              but got a ${builtins.typeOf rawEcosystems}.
            '';

        # The source supplying the `nixpkgs-lib` part of the stack: the
        # part declared separately, else the tree's nixpkgs (one pin
        # supplies every part), else a pinned source named exactly as
        # either; null when nothing declares it.
        nixpkgsLibSource =
          let
            # The plain function rather than the function in the
            # composed library: the source decides what the fixpoint
            # holds, so it cannot be read out of the fixpoint.
            resolve = import ../resolve/resolve.nix;
            fromPart = resolve {
              name = "nixpkgs-lib";
              defaults = defaultEcosystemSrc;
              inherit sources;
            };
            fromNixpkgs = resolve {
              name = "nixpkgs";
              defaults = defaultEcosystemSrc;
              inherit sources;
            };
          in
          if fromPart != null then fromPart else fromNixpkgs;

        # The entries caisson-core publishes into every composition,
        # reachable from an overlay file's closure as `entries.<name>`.
        # They are read back from the registry, so a registration
        # under the same name is what importers get: replacing a
        # published entry is registering under its name. (A replacement
        # that imports the entry it replaces imports itself.)
        publishedEntries = {
          nixpkgs-lib = registeredLibOverlays.nixpkgs-lib;
        };

        # `modules` and `configs` are functions of the bootstrap lib: the
        # selected entries are in it, the module registrations are not.
        modules =
          if builtins.isFunction rawModules then
            rawModules bootstrapLib
          else
            throw ''
              mkLib expects `modules` to be a function taking the bootstrap
              library (`lib: { ... }`), but got a ${builtins.typeOf rawModules}. Take
              the argument and ignore it (`_lib: { ... }`) if you do not need it.
            '';
        # The configurations of this tree, keyed by module class then
        # name (`configs/<class>/<name>` on disk): the modules a top
        # evaluates and a configuration evaluates beneath itself,
        # referenced by name rather than by path. Local registrations
        # only; consumed projects contribute none.
        configs =
          if builtins.isFunction rawConfigs then
            rawConfigs bootstrapLib
          else
            throw ''
              mkLib expects `configs` to be a function taking the bootstrap
              library (`lib: { ... }`), but got a ${builtins.typeOf rawConfigs}. Take
              the argument and ignore it (`_lib: { ... }`) if you do not need it.
            '';
        libOverlays =
          if builtins.isFunction rawLibOverlays then
            rawLibOverlays mkLibOverlayHere
          else
            throw ''
              mkLib expects `libOverlays` to be a function taking the
              input-closed mkLibOverlay helper (`mkLibOverlay: { ... }`), but
              got a ${builtins.typeOf rawLibOverlays}. Take the argument and
              ignore it (`_mkLibOverlay: { ... }`) if you only register
              already-built overlays.
            '';

        localPkgOverlays =
          if builtins.isFunction rawPkgOverlays then
            rawPkgOverlays (mkPkgOverlayFor {
              inherit sources finalLib;
            })
          else
            throw ''
              mkLib expects `pkgOverlays` to be a function taking the
              composition-bound mkPkgOverlay helper (`mkPkgOverlay: { ... }`),
              usually `mkPkgOverlays ./pkg-overlays`, but got a
              ${builtins.typeOf rawPkgOverlays}.
            '';

        # The package overlay registry: consumed projects' entries, then
        # the local registrations, a local name winning a collision as in
        # the lib overlay registry. An entry's key is its registry name.
        # Every entry records where it came from in `project`: null for a
        # local registration, the project's name for a contributed entry,
        # so an export selector can keep the local entries alone with a
        # filter on that field.
        registeredPkgOverlays =
          projectPkgOverlays
          // builtins.mapAttrs (
            name: entry:
            let
              local =
                e:
                e
                // {
                  project = e.project or null;
                  imports = builtins.map local (e.imports or [ ]);
                };
            in
            local (rekeyPkgOverlay (key: key) name entry)
          ) localPkgOverlays;

        # The same construction as the composition's
        # `caisson-core.mkLibOverlay`, bound before the fixpoint
        # exists: the registered overlay set is what the fixpoint is
        # built from, so it cannot be read back out of it.
        mkLibOverlayHere = mkLibOverlayFor {
          inherit sources;
          extraOverlayClosure = {
            closure-lib = finalLib;
            mkModule = finalLib.caisson-core.mkModule;
            inherit contributeClasses contributeModules;
            entries = publishedEntries;
          };
        };

        # caisson-core's entries, bound to this composition.
        coreOverlays = coreEntries {
          inherit sources;
          entries = publishedEntries;
        };

        # The registry: the forced entries caisson-core publishes,
        # then consumed projects' overlays, then the local
        # registrations, prefixed names beside short names; a later
        # registration wins a name collision, so a local registration
        # beats a project's registration and either beats a published
        # entry. A registered overlay's compose key is its registry
        # name here, whatever
        # key it carried from the tree that built it (two projects may
        # each export a `default`), so registering under a published
        # name replaces that entry wherever it is composed.
        #
        # Every entry records where it came from in `project`: the
        # consumed project's name for a contributed entry, null for a
        # local registration, and `caisson-core` for the entries
        # caisson-core publishes into every composition, which this
        # composition did not register either. An export selector keeps
        # the local entries with a filter on `project == null`.
        registeredLibOverlays = builtins.mapAttrs (name: overlay: overlay // { key = name; }) (
          forcedLibOverlays
          // {
            nixpkgs-lib = mkNixpkgsLibEntry nixpkgsLibSource // {
              project = "caisson-core";
            };
          }
          // projectLibOverlays
          // builtins.mapAttrs (_: overlay: overlay // { project = null; }) libOverlays
        );

        # caisson-core's forced entries as the core stage composes them:
        # the entries it ships, whatever the registry holds under their
        # keys. The
        # registry is grafted onto the core lib and so cannot change it;
        # a same-key registration replaces a forced entry from the
        # bootstrap stage on.
        forcedLibOverlays = builtins.mapAttrs (
          name: overlay:
          overlay
          // {
            key = name;
            project = "caisson-core";
          }
        ) coreOverlays;

        # The selection: caisson-core's entries are always composed and
        # first; the rest is what `libOverlayImports` selects, given the
        # core lib. By default it selects the registry's project and
        # local entries. The published entries are not in the default:
        # `nixpkgs-lib` is composed wherever an overlay imports it, and
        # nowhere otherwise. `compose` deduplicates by key, so an entry
        # imported twice, or a forced entry named again, composes once.
        coreNames = builtins.attrNames coreOverlays;
        publishedNames = coreNames ++ [ "nixpkgs-lib" ];
        libOverlayImports =
          if builtins.isFunction rawLibOverlayImports then
            rawLibOverlayImports coreLib
          else
            throw ''
              mkLib expects `libOverlayImports` to be a function taking the core
              lib and returning the entries to compose
              (`lib: [ lib.caisson-core.nixpkgs-lib.overlays.<name> ]`), but
              got a ${builtins.typeOf rawLibOverlayImports}.
            '';
        importedLibOverlays =
          builtins.map (name: registeredLibOverlays.${name}) coreNames
          ++ (
            if builtins.isList libOverlayImports then
              libOverlayImports
            else
              throw ''
                mkLib expects `libOverlayImports` to return a list of registered
                entries, but it returned a ${builtins.typeOf libOverlayImports}.
              ''
          );

        # Consumed projects' modules enter the registry like overlay
        # contributions: available to every selection, beaten by a
        # same-named local registration.
        projectModulesOverlay = {
          imports = [ ];
          overlay = _final: prev: contributeModules prev projectModules;
        };

        # The composing flake's registrations apply last, so a
        # local name deterministically beats a same-named
        # overlay-borne contribution.
        localModulesOverlay = {
          imports = [ ];
          overlay = _final: prev: contributeModules prev modules;
        };

        # The manifest's module dictionary, like its overlay
        # dictionary, is the registered union: consumed projects'
        # prefixed entries with the local registrations on top.
        registeredModules =
          projectModules
          // builtins.listToAttrs (
            builtins.map (class: {
              name = class;
              value = (projectModules.${class} or { }) // modules.${class};
            }) (builtins.attrNames modules)
          );

        # Beside the module dictionary, per class and name, the project
        # a registered module came from: null for a local registration
        # (including a registration that shadows a project's entry of
        # the same name), the project's name otherwise. An export
        # selector keeps the local modules with a filter on this.
        registeredModuleProjects =
          projectModuleProjects
          // builtins.listToAttrs (
            builtins.map (class: {
              name = class;
              value =
                (projectModuleProjects.${class} or { }) // builtins.mapAttrs (_: _: null) modules.${class};
            }) (builtins.attrNames modules)
          );

        # The lib is built in stages, each a new fixpoint over the
        # seed, and each carrying a manifest as `libManifest`, so
        # `lib.caisson-core.libManifest` is always the record of
        # the lib being read at the stage that lib is at. Each stage
        # exists because something is a function of it.
        #
        #   - The core lib: caisson-core's forced entries, with the lib
        #     overlay registry grafted onto its manifest. It is the lib
        #     `libOverlayImports` receives.
        #   - The bootstrap lib: the forced entries and the selection. It
        #     is the lib the `modules` and `configs` functions receive,
        #     so its manifest lacks what they register, and `pkgOverlays`
        #     with them.
        #   - The registered lib: the same entries with those
        #     registrations grafted on, and the modules they register
        #     composed into the module registry view. It is the lib the
        #     `pkgSets` function receives: a package config is a module
        #     evaluation over the registered modules and package
        #     overlays, so it needs them, and its manifest lacks
        #     `pkgSets`, which is what a package config's parent must
        #     lack.
        #   - The full lib: the same lib with `pkgSets` grafted on. It
        #     is the lib mkLib returns.
        #
        # The core, bootstrap and registered manifests are childless:
        # they are records of a lib before everything beneath it
        # exists. The full
        # lib is the full lib of a root declaration, so it is not
        # childless and its chain is empty: no parent, no ancestors,
        # nothing consumed and no children; the package configs it
        # declares are inputs of what is built under it, recorded in
        # `pkgSets`. Every stage shares the declared facts. `sources`
        # are the pinned sources with each pin recorded against the root,
        # `root` is the tree's identity, and `name` is the declared
        # project name, absent when none is declared. The registries are
        # the registered dictionaries (project entries under
        # `<project>/<name>`, locals winning a name collision), so
        # export selections drawn
        # from the manifest see project-borne entries exactly like
        # hand-registered entries; `projects` keeps the raw per-project
        # capture. Checks belong to the export side (integrations), not
        # here.
        stageManifest = {
          _type = "caisson-manifest";
          type = "lib";
          inherit
            defaultEcosystemSrc
            projects
            root
            systems
            ;
          sources = recordedSources;
          libOverlays = registeredLibOverlays;
          inputs = [ ];
          parent = null;
          ancestors = [ ];
          nearest = { };
          children = { };
        }
        // (if name == null then { } else { inherit name; });

        coreManifest = stageManifest // {
          childless = true;
          entries = builtins.map (key: {
            inherit key;
            opaque = false;
          }) coreNames;
          history = coreHistory;
        };

        bootstrapManifest = stageManifest // {
          childless = true;
          inherit entries;
          history = bootstrapHistory;
        };

        registeredManifest = stageManifest // {
          childless = true;
          inherit configs entries;
          history = registeredHistory;
          modules = registeredModules;
          moduleProjects = registeredModuleProjects;
          pkgOverlays = registeredPkgOverlays;
        };

        # The package configs, declared in the lib phase so that every
        # evaluation under this lib can read their sets from the
        # manifest. The `pkgSets` function receives the registered lib,
        # and each config it declares is a function of `{ name, parent }`
        # that an integration's `mkConfiguration` returned, called here
        # with the name it is declared under and the registered manifest
        # as its parent. That manifest lacks
        # `pkgSets`, so the full manifest lists them without containing
        # itself.
        pkgSets =
          let
            declared =
              if builtins.isFunction rawPkgSets then
                rawPkgSets registeredLib
              else
                throw ''
                  mkLib expects `pkgSets` to be a function taking the library
                  with the registrations (`lib: { <name> = <package config>; }`),
                  but got a ${builtins.typeOf rawPkgSets}.
                '';
          in
          if builtins.isAttrs declared then
            builtins.mapAttrs (
              name: child:
              let
                finalized = finalizeChild {
                  inherit name;
                  parent = registeredManifest;
                  what = "`pkgSets.${name}`";
                } child;
              in
              # A package config is a manifest that holds its sets by
              # system, not a configuration evaluated at a system.
              if isManifest finalized then
                finalized
              else
                throw "The package config `pkgSets.${name}` did not return a manifest."
            ) declared
          else
            throw ''
              mkLib expects `pkgSets` to return an attribute set of package
              configs keyed by config name, but it returned a
              ${builtins.typeOf declared}.
            '';

        fullManifest = registeredManifest // {
          childless = false;
          inherit history pkgSets;
        };

        # The constructors that make registry entries, as the core,
        # bootstrap and registered libs hold them. A registration closes over its
        # author's composition, the lib whose `caisson-core.modules` is
        # the author's registry, and for the registrations made at those
        # stages that is the full lib, not the lib the registry function
        # receives. So `mkModule` there, and every class-bound `mkModule`
        # made from it (the integrations' and the class index that
        # `mkModules` reads), closes over the full lib, as the helpers
        # handed to `libOverlays` and `pkgOverlays` do.
        registrationConstructors = {
          mkModule = mkModuleForComposition {
            inherit sources finalLib;
          };
          mkLibOverlay = mkLibOverlayHere;
          mkPkgOverlay = mkPkgOverlayFor {
            inherit sources finalLib;
          };
        };

        # A stage's manifest enters its lib through composition, as a
        # final overlay setting `libManifest`.
        manifestOverlay = manifest: extra: {
          imports = [ ];
          overlay = _final: prev: {
            caisson-core =
              (prev.caisson-core or { })
              // extra
              // {
                libManifest = manifest;
              };
          };
        };

        published = builtins.listToAttrs (
          builtins.map (name: {
            inherit name;
            value = registeredLibOverlays.${name};
          }) publishedNames
        );

        # The phase manifests a later phase fills in on a lib it hands
        # out: `pkgsManifest` on the lib inside a package set,
        # `evalManifest` on the lib a module evaluation is built with.
        # `libManifest` is the record of the stage itself and is not
        # among them.
        phaseManifests = [
          "pkgsManifest"
          "evalManifest"
        ];
        checkedManifests =
          given:
          if !builtins.isAttrs given then
            throw ''
              caisson-core.withManifests expects an attribute set of phase
              manifests (`{ pkgsManifest = <manifest>; }`), but got a ${builtins.typeOf given}.
            ''
          else
            let
              # Refused when the attribute set is merged, not when a
              # manifest is read: an unknown name such as `libManifest`
              # is shadowed by the stage's binding and would never
              # be read.
              unknown = builtins.filter (attr: !(builtins.elem attr phaseManifests)) (
                builtins.attrNames given
              );
            in
            if unknown != [ ] then
              throw ''
                caisson-core.withManifests fills in ${builtins.concatStringsSep " and " phaseManifests},
                but was given `${builtins.head unknown}`.
              ''
            else
              builtins.mapAttrs (
                attr: value:
                if value == null || (builtins.isAttrs value && (value._type or null) == "caisson-manifest") then
                  value
                else
                  throw ''
                    caisson-core.withManifests expects `${attr}` to be a manifest
                    (an attribute set with `_type = "caisson-manifest"`) or null.
                  ''
              ) given;

        # A stage of the lib, composed from its overlays with its
        # manifest and the given phase manifests filled in. The stage
        # carries `caisson-core.withManifests`, which rebuilds it from
        # the same declaration with more phase manifests filled in: a
        # new fixpoint, so everything that reads a phase manifest
        # through the fixpoint sees it, and not an attribute merge over
        # a built lib.
        stage =
          {
            composeArgs,
            overlays,
            manifest,
            extra,
          }:
          filled:
          composeRegistered composeArgs (
            overlays
            ++ [
              (manifestOverlay manifest (
                extra
                // filled
                // {
                  withManifests =
                    more:
                    (stage {
                      inherit
                        composeArgs
                        overlays
                        manifest
                        extra
                        ;
                    } (filled // checkedManifests more)).lib;
                }
              ))
            ]
          );

        coreComposition = stage {
          composeArgs = { };
          overlays = builtins.map (name: forcedLibOverlays.${name}) coreNames;
          manifest = coreManifest;
          extra = registrationConstructors;
        } { };
        coreLib = coreComposition.lib;

        bootstrapComposition = stage {
          composeArgs = { inherit published; };
          overlays = importedLibOverlays;
          manifest = bootstrapManifest;
          extra = registrationConstructors;
        } { };
        bootstrapLib = bootstrapComposition.lib;

        registeredComposition = stage {
          composeArgs = { inherit published; };
          overlays = importedLibOverlays ++ [
            projectModulesOverlay
            localModulesOverlay
          ];
          manifest = registeredManifest;
          extra = registrationConstructors // {
            inherit configs;
          };
        } { };
        registeredLib = registeredComposition.lib;

        composition = stage {
          composeArgs = { inherit published; };
          overlays = importedLibOverlays ++ [
            projectModulesOverlay
            localModulesOverlay
          ];
          manifest = fullManifest;
          extra = { inherit configs; };
        } { };
        finalLib = composition.lib;

        # The manifest's `entries`: the selection's keys in composition
        # order, caisson-core's forced entries first. A key that names
        # no registry entry (a keyless import's synthesized key, or a
        # key an overlay built elsewhere carried in) is an ad hoc
        # entry and marked opaque, as is each keyless entry, which the
        # composition applies after the keyed entries. The walk is over
        # the selection alone: the registrations and the manifest
        # compose after it as caisson-core's recording, not as
        # entries.
        selectionMeta = (composeRegistered { inherit published; } importedLibOverlays).meta;
        entries =
          builtins.map (key: {
            inherit key;
            opaque = !(registeredLibOverlays ? ${key});
          }) selectionMeta.order
          ++ builtins.genList (i: {
            key = "keyless/${toString i}";
            opaque = true;
          }) selectionMeta.tailLength;

        # The manifest's `history`: the events recorded on the way to
        # the lib, in stage order, the history of each stage beginning
        # with the history of the stage before it. The core stage
        # records its forced entries, one `layer` event each, then the
        # lib overlay registrations grafted onto it. The bootstrap stage
        # adds a `layer` event for each entry it composes that the core
        # stage did not: the selection, and a registration replacing a
        # forced entry under its key, which comes after the entry it
        # replaces, so `definers` names it the winner. The registered
        # stage adds the `modules`, `configs` and `pkgOverlays`
        # registrations, and the full stage the `pkgSets` registrations.
        #
        # Each event names its manifest (the empty name path: this is
        # the root lib), its type and operation, its key, its index
        # within its operation and its origin, the project that
        # registered it (this project's name for a local entry) and the
        # file it was built from where that is known. A layer event also
        # carries the sides of its overlay call,
        # `final: prev: result`, as the stage that recorded it composed
        # them: `result`, the attrset its overlay returned (the names
        # the layer defines, where it binds them and the values they
        # had after it), and `prev`, the accumulation it received,
        # which tells a name it defines from a name it carries over;
        # `definers` reads both lazily.
        originOf = entry: {
          project = if (entry.project or null) == null then name else entry.project;
          file = entry.origin or null;
        };
        libOverlayRegistrations = builtins.map (n: {
          key = "libOverlays.${n}";
          origin = originOf registeredLibOverlays.${n};
        }) (builtins.attrNames registeredLibOverlays);
        registeredRegistrations =
          builtins.concatMap (
            class:
            builtins.map (n: {
              key = "modules.${class}.${n}";
              origin = {
                project =
                  let
                    project = registeredModuleProjects.${class}.${n} or null;
                  in
                  if project == null then name else project;
                file = null;
              };
            }) (builtins.attrNames registeredModules.${class})
          ) (builtins.attrNames registeredModules)
          ++ builtins.concatMap (
            class:
            builtins.map (n: {
              key = "configs.${class}.${n}";
              origin = {
                project = name;
                file = null;
              };
            }) (builtins.attrNames configs.${class})
          ) (builtins.attrNames configs)
          ++ builtins.map (n: {
            key = "pkgOverlays.${n}";
            origin = originOf registeredPkgOverlays.${n};
          }) (builtins.attrNames registeredPkgOverlays);
        pkgSetRegistrations = builtins.map (n: {
          key = "pkgSets.${n}";
          origin = {
            project = name;
            file = null;
          };
        }) (builtins.attrNames pkgSets);
        registryEvents =
          offset: registrations:
          builtins.genList (
            i:
            let
              registration = builtins.elemAt registrations i;
            in
            {
              manifest = [ ];
              type = "lib";
              operation = "registry";
              index = offset + i;
              inherit (registration) key origin;
            }
          ) (builtins.length registrations);
        layerEvents =
          offset: layers:
          builtins.genList (
            i:
            let
              recorded = builtins.elemAt layers i;
            in
            {
              manifest = [ ];
              type = "lib";
              operation = "layer";
              index = offset + i;
              inherit (recorded) key;
              origin =
                if recorded.registered != null then
                  originOf recorded.registered
                else
                  {
                    project = null;
                    file = null;
                  };
              inherit (recorded.layer) result prev;
            }
          ) (builtins.length layers);

        # The forced entries' layers, as the core stage composed them.
        coreLayers = builtins.genList (
          i:
          let
            layer = builtins.elemAt coreComposition.layers i;
          in
          {
            inherit layer;
            inherit (layer.entry) key;
            registered = forcedLibOverlays.${layer.entry.key};
          }
        ) (builtins.length coreNames);

        # The bootstrap stage's layers, less the forced entries it
        # composes unchanged, which the core stage already recorded.
        keyedLength = builtins.length selectionMeta.order;
        selectionLength = keyedLength + selectionMeta.tailLength;
        unchangedForced =
          key: forcedLibOverlays ? ${key} && (registeredLibOverlays.${key}.project or null) == "caisson-core";
        bootstrapLayers = builtins.filter (recorded: !(unchangedForced recorded.key)) (
          builtins.genList (
            i:
            let
              layer = builtins.elemAt bootstrapComposition.layers i;
              key =
                if (layer.entry.key or null) != null then layer.entry.key else "keyless/${toString (i - keyedLength)}";
            in
            {
              inherit layer key;
              registered = registeredLibOverlays.${key} or null;
            }
          ) selectionLength
        );

        coreHistory = layerEvents 0 coreLayers ++ registryEvents 0 libOverlayRegistrations;
        bootstrapHistory = coreHistory ++ layerEvents (builtins.length coreLayers) bootstrapLayers;
        registeredHistory =
          bootstrapHistory ++ registryEvents (builtins.length libOverlayRegistrations) registeredRegistrations;
        history =
          registeredHistory
          ++ registryEvents (
            builtins.length libOverlayRegistrations + builtins.length registeredRegistrations
          ) pkgSetRegistrations;

      in
      # Surface argument-shape errors as soon as the result is used,
      # rather than wherever the offending argument happens to be
      # forced first. `||` forces the throw-carrying binding only when
      # the argument is malformed.
      builtins.foldl' (acc: check: builtins.seq check acc) finalLib [
        sources
        (rawRoot == null || (builtins.isAttrs rawRoot && rawRoot ? outPath) || root)
        (builtins.isFunction rawModules || modules)
        (builtins.isFunction rawConfigs || configs)
        (builtins.isFunction rawLibOverlays || libOverlays)
        (builtins.isFunction rawLibOverlayImports || libOverlayImports)
        (builtins.isFunction rawPkgOverlays || localPkgOverlays)
        (builtins.isFunction rawPkgSets || pkgSets)
        (builtins.isAttrs rawEcosystems || defaultEcosystemSrc)
        (builtins.isAttrs rawProjects || projects)
        (rawSystems == null || builtins.isList rawSystems || systems)
        (rawName == null || builtins.isString rawName || name)
      ]
    );

in
{
  overlay = final: prev: {
    caisson-core = (prev.caisson-core or { }) // {
      inherit
        contributeClasses
        contributeModules
        coreEntries
        definers
        elide
        finalizeChild
        importApply
        manifestOf
        mkExtendedLib
        mkLib
        mkNixpkgsLibEntry
        pkgOverlaysFor
        ;
      mkConfiguration = mkConfigurationFor final;
      finalizeTop = finalizeTopFor final;
      mkPkgOverlay = mkPkgOverlayFor {
        sources = closure-inputs;
        finalLib = final;
      };
      mkModule = mkModuleForComposition {
        sources = closure-inputs;
        finalLib = final;
      };
      mkLibOverlay = mkLibOverlayFor {
        sources = closure-inputs;
        # Lazily bound, so overlay files that contribute no modules do
        # not force the composed fixpoint through these.
        extraOverlayClosure = {
          closure-lib = final;
          mkModule = final.caisson-core.mkModule;
          inherit contributeClasses contributeModules entries;
        };
      };
      # Seed only: overlay contributions merge in during composition,
      # and mkLib applies the local registrations as a final overlay
      # so the composing flake's entries win over contributed
      # entries.
      modules = (prev.caisson-core or { }).modules or { };
      # The class index: per class, the integration that owns it and
      # the mkModule the class registers through. Each integration
      # declares the class it owns (contributeClasses); the class-free
      # `generic` class, whose modules any class may import, is
      # declared here, since no integration owns it.
      classes = {
        generic = {
          integration = "caisson-core";
          mkModule = final.caisson-core.mkModule "generic";
        };
      }
      // ((prev.caisson-core or { }).classes or { });
      # The configurations registry, filled by mkLib.
      configs = (prev.caisson-core or { }).configs or { };
      # The phase manifests, one per evaluation phase: the lib (filled
      # in by mkLib), the package set (filled in on the lib inside a
      # package set) and the module evaluation (filled in on the lib an
      # evaluation is built with). All are present on every
      # composed library and null until filled in.
      libManifest = (prev.caisson-core or { }).libManifest or null;
      pkgsManifest = (prev.caisson-core or { }).pkgsManifest or null;
      evalManifest = (prev.caisson-core or { }).evalManifest or null;
      # The lib overlay registry visible at this lib, by registry name:
      # a view of the manifest's `libOverlays`, which a selection
      # refers into (`libOverlayImports = lib: [
      # lib.caisson-core.nixpkgs-lib.overlays.<name> ];`). Empty in a
      # library no mkLib built.
      nixpkgs-lib = ((prev.caisson-core or { }).nixpkgs-lib or { }) // {
        overlays =
          let
            manifest = final.caisson-core.libManifest;
          in
          if manifest == null then { } else manifest.libOverlays or { };
      };
    };
  };
}
