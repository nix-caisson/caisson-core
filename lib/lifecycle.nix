# SPDX-License-Identifier: MIT
#
# The library lifecycle: building a composed library from registered
# overlays and modules over the empty seed, and injecting the
# `caisson-core` namespace (machinery, registry, manifest) into the
# result.  mkLib is the entry point; mkCoreOverlay is the same
# injection as a standalone entry for compositions assembled
# with `compose` directly.
#
# Contracts, shared with `compose`:
#
#   - Nothing is composed over: every function a library holds
#     arrives as an entry, nixpkgs' library included (the published
#     `nixpkgs-lib` entry, composed as upstream fixes it).
#   - The source of that entry is the tree's declared
#     `defaultEcosystemSrc.nixpkgs-lib` or `.nixpkgs`, or an input
#     named exactly so, through `resolve`; a miss is null, and the
#     entry names the declaration only where it is composed.
#   - Only this file puts things into the composed library's
#     `caisson-core` namespace.  The manifest (the capture of what
#     mkLib consumed) enters through composition as a synthetic
#     final overlay, the same channel as everything else.
#
# This file uses builtins only, on purpose.  Nothing here may
# reference nixpkgs' library (or any other library).

{
  compose,
  resolve,
  callFlake,
  partitionExtraInputs,
}:

let

  # Use a list of built overlays (`{ imports, overlay }` attrsets,
  # imports applied before the overlay itself) to extend a base
  # library.  The chain is flattened depth-first, imports before self,
  # duplicates preserved, and applied as anonymous entries over the
  # base.  The order is part of the contract: an overlay may rely on
  # its imports having applied before it.
  # Compose registered overlays into a library. The seed is the empty
  # attribute set: nothing is composed over, and everything a library
  # holds arrives as an entry. A keyed overlay keeps its key, so
  # `compose` deduplicates it and a same-key overlay registered later
  # replaces it; a keyless overlay joins the tail in list order.
  # Keyless imports are flattened in front of their importer as
  # before; keyed imports stay imports, which `compose` walks.
  #
  # `published` maps a key to the entry the composing tree holds under
  # it. An import addresses a stable identity, so an overlay built in
  # another tree that imports that tree's `nixpkgs-lib` entry gets
  # this tree's when composed here: every keyed entry or import whose
  # key is published is read from the map, not from the value the
  # importer carried.
  composeRegistered =
    { published ? { } }:
    let
      isKeyed = overlay: (overlay.key or null) != null;
      byKey = overlay: if isKeyed overlay && published ? ${overlay.key} then published.${overlay.key} else overlay;
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
    overlays: (compose { entries = builtins.concatMap flattenOverlay overlays; }).lib;

  mkExtendedLib = composeRegistered { };

  # The entry that brings nixpkgs' library into a composition: the
  # functions of the source supplying the `nixpkgs-lib` part of the
  # stack, as that source fixes them. (nixpkgs' lib/default.nix builds
  # its fixpoint with a bootstrap makeExtensible that exposes `extend`
  # only, no `__unfix__`, so the library cannot be re-tied over the
  # composed fixpoint here; a polyfill composed later overrides a
  # name for readers of the composed lib, not for upstream's own
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
              in the mkLib call, or give the composing flake an input named exactly
              `nixpkgs-lib` or `nixpkgs`.
            ''
          else
            "${src}";
        libDir = if builtins.pathExists "${root}/lib/default.nix" then "${root}/lib" else root;
      in
      prev // import libDir;
  };

  # Build a composition-bound mkLibOverlay: everything passed to it
  # takes the closure attrset, `{ closure-inputs, mkLibOverlay, ... }:`,
  # as its first arg list, and returns an `{ imports ? [ ], overlay }`
  # attrset.  Already-built overlays (e.g. another flake's exported
  # libOverlays) are registered directly rather than wrapped.
  mkLibOverlayFor =
    {
      inputs,
      # Extra attrs merged into the closure applied to overlay files;
      # mkLib threads the composition's mkModule and the static
      # contributeModules helper through here so overlays can
      # contribute modules closed over their own flake.
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
                    closure-inputs = inputs;
                    inherit mkLibOverlay;
                  }
                  // extraOverlayClosure
                )
              else
                throw ''
                  ${provenance}mkLibOverlay expects a function taking the closure attrset
                  (`{ closure-inputs, mkLibOverlay, ... }:`) as its first arg list, but got
                  a ${builtins.typeOf reified}. Register already-built overlays directly
                  instead of wrapping them in mkLibOverlay.
                '';
          in
          if (builtins.isAttrs applied) && (builtins.hasAttr "overlay" applied) then
            {
              imports = applied.imports or [ ];
              overlay = applied.overlay;
            }
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

  # Build a composition-bound, class-parameterized mkModule.
  # `selfModules` is the composing flake's own class-keyed
  # registration set (for closure-self-modules); `finalLib` is the
  # composed fixpoint (for closure-lib), bound lazily.
  mkModuleForComposition =
    {
      inputs,
      selfModules ? { },
      finalLib,
    }:
    let
      mkModuleClass =
        moduleClass:
        let
          mkModule = mkModuleClass moduleClass;
          closureArgs = {
            inherit mkModule;
            closure-inputs = inputs;
            closure-lib = finalLib;
            closure-self-modules = selfModules.${moduleClass} or { };
          };
        in
        freeformModule:
        (
          # Everything passed to mkModule takes the closure attrset as its first
          # arg list: `{ closure-inputs, closure-lib, closure-self-modules, mkModule, ... }: <module>`.
          let
            applyClosure =
              m:
              if builtins.isFunction m then
                m closureArgs
              else
                throw ''
                  mkModule (class `${moduleClass}`) expects a module function taking the
                  closure attrset (`{ closure-inputs, closure-lib, closure-self-modules, mkModule, ... }:`) as
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

  # Evaluate a consumer-style flake from source with explicitly
  # supplied inputs. The flake's declared inputs resolve by name:
  # `overrides` first, then `follows` chains through the other
  # resolved inputs, then `pool`; anything else throws, naming the
  # input. The self fixpoint and decoration (`inputs`, `outputs`,
  # `outPath`, `_type`) are handled by the shared call-flake kernel.
  # Nothing is fetched: URL-declared inputs must
  # be supplied (test-only pins conventionally come from a
  # tests/dependencies flake). Locks, follows across unsupplied
  # inputs, and sourceInfo are not consulted or emulated.
  callConsumerFlake =
    {
      path,
      pool ? { },
      overrides ? { },
      # forwarded to the self attrset for subjects that read
      # sourceInfo attrs (lastModified, rev, ...)
      sourceInfo ? { },
    }:
    let
      flakeExpr = import (path + "/flake.nix");
      declared = flakeExpr.inputs or { };

      segments = s: builtins.filter (x: builtins.isString x && x != "") (builtins.split "/" s);

      missingFor =
        name: spec:
        throw ''
          callConsumerFlake: input `${name}` of ${builtins.toString path} is declared
          as ${
            if (builtins.isAttrs spec) && (spec ? follows) then
              "`follows = \"${spec.follows}\"`"
            else if (builtins.isAttrs spec) && (spec ? url) then
              "`url = \"${spec.url}\"`"
            else
              "an input"
          } but could not be resolved. Supply it via `pool` or `overrides`;
          nothing is fetched here.
        '';

      followsOrPool =
        name: followsPath:
        let
          segs = segments followsPath;
          headName = builtins.head segs;
          base =
            if builtins.hasAttr headName resolvedDeclared then
              resolvedDeclared.${headName}
            else
              pool.${headName} or null;
          step = acc: seg: if acc == null then null else ((acc.inputs or { }).${seg} or null);
          followed = builtins.foldl' step base (builtins.tail segs);
        in
        if followed != null then followed else pool.${name} or (missingFor name { follows = followsPath; });

      resolveName =
        name: spec:
        if builtins.hasAttr name overrides then
          overrides.${name}
        else if (builtins.isAttrs spec) && (spec ? follows) then
          followsOrPool name spec.follows
        else
          pool.${name} or (missingFor name spec);

      resolvedDeclared = builtins.mapAttrs resolveName declared;
    in
    callFlake {
      src = path;
      inputs = resolvedDeclared // overrides;
      inherit sourceInfo;
    };

  # The `caisson-core` namespace injection as a built overlay: the
  # machinery bound to one composition.  mkLib applies it first; a
  # consumer composing entries directly can apply it as (part
  # of) a keyed entry.  The registry seed preserves anything already
  # contributed; local registrations win because mkLib applies them
  # after every imported overlay.
  mkCoreOverlay =
    {
      inputs,
      # The composing flake's class-keyed registrations, for
      # closure-self-modules.  Empty for compositions with no
      # registration phase.
      selfModules ? { },
      # The published entries an overlay file may import from its
      # closure (`{ entries, ... }:`), the `nixpkgs-lib` entry among
      # them. Empty for compositions assembled without mkLib.
      entries ? { },
    }:
    {
      # The core entry: registered under this key like any entry, so
      # the registry shows it and a same-key entry replaces it.
      key = "caisson-core";
      imports = [ ];
      overlay = final: prev: {
        caisson-core = (prev.caisson-core or { }) // {
          inherit
            compose
            resolve
            importApply
            callConsumerFlake
            partitionExtraInputs
            mkLib
            mkNixpkgsLibEntry
            ;
          mkModule = mkModuleForComposition {
            inherit inputs selfModules;
            finalLib = final;
          };
          mkLibOverlay = mkLibOverlayFor {
            inherit inputs;
            # Lazily bound, so overlay files that contribute no
            # modules do not force the composed fixpoint through
            # these.
            extraOverlayClosure = {
              mkModule = final.caisson-core.mkModule;
              inherit contributeModules entries;
            };
          };
          # Seed only: overlay contributions merge in during
          # composition, and mkLib applies the local registrations as
          # a final overlay so the composing flake's own entries win
          # over contributed ones.
          modules = (prev.caisson-core or { }).modules or { };
          # The manifest slots, one per evaluation phase: the lib
          # (filled by mkLib), the package set (filled on the lib
          # inside a package set) and the module evaluation (filled on
          # the lib an evaluation is built with). All three are present
          # on every composed library and null until filled.
          libManifest = (prev.caisson-core or { }).libManifest or null;
          pkgsManifest = (prev.caisson-core or { }).pkgsManifest or null;
          evalManifest = (prev.caisson-core or { }).evalManifest or null;
        };
      };
    };

  mkLib =
    rawArgs:
    (
      let
        resolvedArgs = if builtins.isAttrs rawArgs then rawArgs else throw "mkLib expects an attrset.";

        inputs =
          resolvedArgs.inputs or (throw ''
            mkLib requires `inputs`: the composing flake's inputs, closed over
            by registered overlays and modules.
          '');

        rawModules = resolvedArgs.modules or (composedLib: { });
        rawLibOverlays = resolvedArgs.libOverlays or (mkLibOverlay: { });
        libOverlayImports = resolvedArgs.libOverlayImports or (overlays: builtins.attrValues overlays);
        rawEcosystems =
          if resolvedArgs ? ecosystems then
            throw ''
              mkLib no longer takes `ecosystems`: the tree's default source per
              ecosystem is declared as `defaultEcosystemSrc` (the same shape).
            ''
          else
            resolvedArgs.defaultEcosystemSrc or { };
        rawProjects = resolvedArgs.projects or { };
        rawSystems = resolvedArgs.systems or null;

        # The platforms the tree builds on, declared once here and
        # read from the manifest by whatever needs a system list
        # before any evaluation names a host platform. Null when the
        # composition declares none.
        systems =
          if rawSystems == null || (builtins.isList rawSystems && builtins.all builtins.isString rawSystems) then
            rawSystems
          else
            throw ''
              mkLib expects `systems` to be a list of system strings (e.g.
              `[ "x86_64-linux" ]`), but got a ${builtins.typeOf rawSystems}.
            '';

        # Consumed projects: whole upstream contributions, registered
        # as units.  A project value is assumed to carry `libOverlays`
        # and class-keyed `modules` dictionaries, which a caisson-built
        # flake's outputs already do; the shape is assumed rather than
        # checked (producers validate their own exports).  The
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

        projectLibOverlays = builtins.foldl' (
          acc: projectName: acc // prefixNames projectName (projects.${projectName}.libOverlays or { })
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

        # Declared ecosystem sources: mkLib-time facts, captured in the
        # manifest for the layered resolution higher layers perform
        # (explicit argument, then these declarations, then an input
        # with exactly the declared name). Nothing here interprets
        # them.
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
        # part declared on its own, else the tree's nixpkgs (one pin
        # supplies every part), else an input named exactly as either;
        # null when nothing declares it.
        nixpkgsLibSource =
          let
            fromPart = resolve {
              name = "nixpkgs-lib";
              defaults = defaultEcosystemSrc;
              inherit inputs;
            };
            fromNixpkgs = resolve {
              name = "nixpkgs";
              defaults = defaultEcosystemSrc;
              inherit inputs;
            };
          in
          if fromPart != null then fromPart else fromNixpkgs;

        # The entries caisson-core publishes into every composition,
        # reachable from an overlay file's closure as `entries.<name>`.
        # They are read back from the registry, so a registration
        # under the same name is what importers get: replacing a
        # published entry is registering one. (A replacement that
        # imports the entry it replaces imports itself.)
        publishedEntries = {
          nixpkgs-lib = registeredLibOverlays.nixpkgs-lib;
        };

        modules =
          if builtins.isFunction rawModules then
            rawModules finalLib
          else
            throw ''
              mkLib expects `modules` to be a function taking the composed
              library (`composedLib: { ... }`), but got a ${builtins.typeOf rawModules}. Take
              the argument and ignore it (`_composedLib: { ... }`) if you do not need
              it.
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

        mkLibOverlayHere = mkLibOverlayFor {
          inherit inputs;
          # Lazily bound, as in mkCoreOverlay.
          extraOverlayClosure = {
            mkModule = finalLib.caisson-core.mkModule;
            inherit contributeModules;
            entries = publishedEntries;
          };
        };

        coreOverlay = mkCoreOverlay {
          inherit inputs;
          selfModules = modules;
          entries = publishedEntries;
        };

        # The registry: the forced entries caisson-core publishes,
        # then consumed projects' overlays, then the local
        # registrations, prefixed names beside short ones; a later
        # registration wins a name collision, so a local one beats a
        # project's and either beats a published one. A registered
        # overlay's compose key is its registry name unless it carries
        # a key of its own, so registering under a published name
        # replaces that entry wherever it is composed.
        registeredLibOverlays = builtins.mapAttrs (name: overlay: overlay // { key = overlay.key or name; }) (
          {
            caisson-core = coreOverlay;
            nixpkgs-lib = mkNixpkgsLibEntry nixpkgsLibSource;
          }
          // projectLibOverlays
          // libOverlays
        );

        # The selection: the core entry is always composed and first;
        # the rest is what `libOverlayImports` selects from the
        # registry's project and local entries. The published entries
        # are not selectable: `nixpkgs-lib` is composed wherever an
        # overlay imports it, and nowhere otherwise. `compose`
        # deduplicates by key, so an entry imported twice composes
        # once.
        publishedNames = [
          "caisson-core"
          "nixpkgs-lib"
        ];
        importedLibOverlays = [
          registeredLibOverlays.caisson-core
        ]
        ++ libOverlayImports (builtins.removeAttrs registeredLibOverlays publishedNames);

        # Consumed projects' modules enter the registry like overlay
        # contributions: available to every selection, beaten by a
        # same-named local registration.
        projectModulesOverlay = {
          imports = [ ];
          overlay = _final: prev: contributeModules prev projectModules;
        };

        # The composing flake's own registrations apply last, so a
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

        # The lib manifest: the capture of what mkLib consumed, filled
        # into the `libManifest` slot through composition like
        # everything else.  Its dictionaries are the registered ones
        # (project entries under `<project>/<name>`, locals winning a
        # name collision), so export selections drawn from the
        # manifest see project-borne entries exactly like
        # hand-registered ones; `projects` keeps the raw per-project
        # capture.  The injector is internal and appears in neither
        # dictionary, so the only cycles run through function
        # closures, which no traversal enters.  Checks belong to the
        # export side (integrations), not here.
        manifestOverlay = {
          imports = [ ];
          overlay = _final: prev: {
            caisson-core = (prev.caisson-core or { }) // {
              libManifest = {
                inherit
                  defaultEcosystemSrc
                  inputs
                  projects
                  systems
                  ;
                libOverlays = registeredLibOverlays;
                modules = registeredModules;
              };
            };
          };
        };

        finalLib =
          composeRegistered
            {
              published = builtins.listToAttrs (
                builtins.map (name: {
                  inherit name;
                  value = registeredLibOverlays.${name};
                }) publishedNames
              );
            }
            (
              importedLibOverlays
              ++ [
                projectModulesOverlay
                localModulesOverlay
                manifestOverlay
              ]
            );

      in
      # Surface argument-shape errors as soon as the result is used,
      # rather than wherever the offending argument happens to be
      # forced first. `||` only forces the throw-carrying binding in
      # the non-function case.
      builtins.seq (builtins.isFunction rawModules || modules) (
        builtins.seq (builtins.isFunction rawLibOverlays || libOverlays) (
          builtins.seq (builtins.isAttrs rawEcosystems || defaultEcosystemSrc) (
            builtins.seq (builtins.isAttrs rawProjects || projects) (
              builtins.seq (rawSystems == null || builtins.isList rawSystems || systems) finalLib
            )
          )
        )
      )
    );

in
{
  inherit
    callConsumerFlake
    contributeModules
    importApply
    mkCoreOverlay
    mkExtendedLib
    mkLib
    mkNixpkgsLibEntry
    ;
}
