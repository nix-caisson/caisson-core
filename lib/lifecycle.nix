# SPDX-License-Identifier: MIT
#
# The library lifecycle: building a composed library from a base
# library plus registered overlays and modules, and injecting the
# `caisson-core` namespace (machinery, registry, manifest) into the
# result.  mkLib is the entry point; mkCoreOverlay is the same
# injection as a standalone entry for compositions assembled
# with `compose` directly.
#
# Contracts, shared with `compose`:
#
#   - The base is contributed as an opaque attribute set.  Overriding
#     one of its attributes does not re-tie its internal references.
#   - `baseLib` is a plain argument.  Nothing here looks anything up
#     by input name, and there is no miss to report: a caller that
#     wants a default threads one (the injected `caisson-core.mkLib`
#     defaults to its own composition's base).
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
  # duplicates preserved, and applied as anonymous entries
  # over the base, which reproduces the historical fold order exactly.
  mkExtendedLib =
    let
      flattenOverlay =
        overlay:
        if (builtins.isAttrs overlay) && (builtins.hasAttr "overlay" overlay) then
          (builtins.concatMap flattenOverlay (overlay.imports or [ ]))
          ++ [
            {
              key = null;
              imports = [ ];
              overlay = overlay.overlay;
            }
          ]
        else
          throw ''
            Library overlays are `{ imports, overlay }` attrsets (build them
            with mkLibOverlay, or use another flake's exported overlays), but
            composition encountered a ${builtins.typeOf overlay}.
          '';
    in
    overlays: baseLib:
    (compose {
      entries = [
        {
          key = null;
          imports = [ ];
          overlay = _final: _prev: baseLib;
        }
      ]
      ++ builtins.concatMap flattenOverlay overlays;
    }).lib;

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
            # same file passed through mkModule at two sites deduplicates just
            # like importing the same path twice would.
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
      # Default base for re-invocations of the injected mkLib; null
      # keeps `baseLib` required there.
      defaultBaseLib ? null,
    }:
    {
      imports = [ ];
      overlay = final: prev: {
        caisson-core = (prev.caisson-core or { }) // {
          inherit
            compose
            resolve
            importApply
            callConsumerFlake
            partitionExtraInputs
            ;
          mkLib =
            if defaultBaseLib == null then mkLib else (args: mkLib ({ baseLib = defaultBaseLib; } // args));
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
              inherit contributeModules;
            };
          };
          # Seed only: overlay contributions merge in during
          # composition, and mkLib applies the local registrations as
          # a final overlay so the composing flake's own entries win
          # over contributed ones.
          modules = (prev.caisson-core or { }).modules or { };
        };
      };
    };

  mkLib =
    rawArgs:
    (
      let
        resolvedArgs = if builtins.isAttrs rawArgs then rawArgs else throw "mkLib expects an attrset.";

        baseLib =
          resolvedArgs.baseLib or (throw ''
            mkLib requires `baseLib`: the base library to compose over is a
            plain argument (nothing is looked up by input name).
          '');
        inputs =
          resolvedArgs.inputs or (throw ''
            mkLib requires `inputs`: the composing flake's inputs, closed over
            by registered overlays and modules.
          '');

        rawModules = resolvedArgs.modules or (composedLib: { });
        rawLibOverlays = resolvedArgs.libOverlays or (mkLibOverlay: { });
        libOverlayImports = resolvedArgs.libOverlayImports or (overlays: builtins.attrValues overlays);
        rawEcosystems = resolvedArgs.ecosystems or { };
        rawProjects = resolvedArgs.projects or { };

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
        ecosystems =
          if builtins.isAttrs rawEcosystems then
            rawEcosystems
          else
            throw ''
              mkLib expects `ecosystems` to be an attribute set of ecosystem
              sources keyed by their exact names (e.g. `{ nixpkgs = ...; }`),
              but got a ${builtins.typeOf rawEcosystems}.
            '';

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
          };
        };

        # The selection sees consumed projects' overlays beside the
        # local registrations, prefixed names beside short ones; a
        # local registration wins a name collision.
        registeredLibOverlays = projectLibOverlays // libOverlays;
        importedLibOverlays = libOverlayImports registeredLibOverlays;

        coreOverlay = mkCoreOverlay {
          inherit inputs;
          selfModules = modules;
          defaultBaseLib = baseLib;
        };

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

        # The manifest: the capture of what mkLib consumed, injected
        # through composition like everything else.  Its dictionaries
        # are the registered ones (project entries under
        # `<project>/<name>`, locals winning a name collision), so
        # export selections drawn from the manifest see project-borne
        # entries exactly like hand-registered ones; `projects` keeps
        # the raw per-project capture.  The injector is internal and
        # appears in neither dictionary, so the only cycles run
        # through function closures, which no traversal enters.
        # Checks belong to the export side (integrations), not here.
        manifestOverlay = {
          imports = [ ];
          overlay = _final: prev: {
            caisson-core = (prev.caisson-core or { }) // {
              manifest = {
                inherit ecosystems inputs projects;
                libOverlays = registeredLibOverlays;
                modules = registeredModules;
              };
            };
          };
        };

        finalLib = mkExtendedLib (
          [ coreOverlay ]
          ++ importedLibOverlays
          ++ [
            projectModulesOverlay
            localModulesOverlay
            manifestOverlay
          ]
        ) baseLib;

      in
      # Surface argument-shape errors as soon as the result is used,
      # rather than wherever the offending argument happens to be
      # forced first. `||` only forces the throw-carrying binding in
      # the non-function case.
      builtins.seq (builtins.isFunction rawModules || modules) (
        builtins.seq (builtins.isFunction rawLibOverlays || libOverlays) (
          builtins.seq (builtins.isAttrs rawEcosystems || ecosystems) (
            builtins.seq (builtins.isAttrs rawProjects || projects) finalLib
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
    ;
}
