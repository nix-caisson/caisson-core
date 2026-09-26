# SPDX-License-Identifier: MIT
#
# The library lifecycle: building a composed library from registered
# overlays and modules over the empty seed, with the `caisson-core`
# namespace (machinery, registries, manifest) composed into the result
# from caisson-core's own entries. mkLib is the entry point.
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
#   - The `caisson-core` namespace is contributed by caisson-core's own
#     entries and nothing else.  The manifest (the capture of what
#     mkLib consumed) enters through composition as a synthetic final
#     overlay, the same channel as everything else.
#
# This overlay takes the bootstrap closure of caisson-core's own
# entries: the inputs this composition closes over, the entries it
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
  # takes the closure attrset,
  # `{ closure-inputs, closure-lib, mkLibOverlay, ... }:`, as its
  # first arg list, and returns an `{ imports ? [ ], overlay }`
  # attrset.  Already-built overlays (e.g. another flake's exported
  # libOverlays) are registered directly rather than wrapped.
  mkLibOverlayFor =
    {
      inputs,
      # Extra attrs merged into the closure applied to overlay files;
      # the composed fixpoint (closure-lib, so an overlay's functions
      # reach the registry of the composition that registered them),
      # the composition's mkModule and the static contribute helpers
      # arrive through here so overlays can contribute modules and
      # classes closed over their own flake. Bound lazily: an overlay
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
                    closure-inputs = inputs;
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

  # Build a composition-bound, class-parameterized mkModule.
  # `finalLib` is the composed fixpoint (for closure-lib), bound
  # lazily; a module reaches the registry of the composition that
  # registered it through closure-lib, under
  # `caisson-core.modules.<class>`.
  mkModuleForComposition =
    {
      inputs,
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
        rawConfigs = resolvedArgs.configs or (composedLib: { });
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
        rawNamespace = resolvedArgs.namespace or null;

        # The platforms the tree builds on, declared once here and
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

        # The namespace this composition contributes to the composed
        # library: the one name the tree holds for itself, declared
        # once here and read from the manifest. A configuration no
        # parent declares takes it as its name, since a name is
        # otherwise the attribute a parent declares a child under and
        # a parentless evaluation has no such attribute. Null when the
        # composition declares none, which leaves such a configuration
        # unnamed.
        namespace =
          if rawNamespace == null || builtins.isString rawNamespace then
            rawNamespace
          else
            throw ''
              mkLib expects `namespace` to be the string naming the namespace this
              composition contributes to the composed library (e.g. `"my-project"`,
              read as `lib.my-project`), but got a ${builtins.typeOf rawNamespace}.
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
            # The plain function rather than the one in the composed
            # library: the source decides what the fixpoint holds, so
            # it cannot be read out of the fixpoint.
            resolve = import ../resolve/resolve.nix;
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
        # The configurations of this tree, keyed by module class then
        # name (`configs/<class>/<name>` on disk): the modules a top
        # evaluates and a configuration evaluates beneath itself,
        # referenced by name rather than by path. Local registrations
        # only; consumed projects contribute none.
        configs =
          if builtins.isFunction rawConfigs then
            rawConfigs finalLib
          else
            throw ''
              mkLib expects `configs` to be a function taking the composed
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

        # The same construction as the composition's own
        # `caisson-core.mkLibOverlay`, bound before the fixpoint
        # exists: the registered overlay set is what the fixpoint is
        # built from, so it cannot be read back out of it.
        mkLibOverlayHere = mkLibOverlayFor {
          inherit inputs;
          extraOverlayClosure = {
            closure-lib = finalLib;
            mkModule = finalLib.caisson-core.mkModule;
            inherit contributeClasses contributeModules;
            entries = publishedEntries;
          };
        };

        # caisson-core's own entries, bound to this composition.
        coreOverlays = coreEntries {
          inherit inputs;
          entries = publishedEntries;
        };

        # The registry: the forced entries caisson-core publishes,
        # then consumed projects' overlays, then the local
        # registrations, prefixed names beside short ones; a later
        # registration wins a name collision, so a local one beats a
        # project's and either beats a published one. A registered
        # overlay's compose key is its registry name here, whatever
        # key it carried from the tree that built it (two projects may
        # each export a `default`), so registering under a published
        # name replaces that entry wherever it is composed.
        registeredLibOverlays = builtins.mapAttrs (name: overlay: overlay // { key = name; }) (
          coreOverlays
          // {
            nixpkgs-lib = mkNixpkgsLibEntry nixpkgsLibSource;
          }
          // projectLibOverlays
          // libOverlays
        );

        # The selection: caisson-core's entries are always composed and
        # first; the rest is what `libOverlayImports` selects from the
        # registry's project and local entries. The published entries
        # are not selectable: `nixpkgs-lib` is composed wherever an
        # overlay imports it, and nowhere otherwise. `compose`
        # deduplicates by key, so an entry imported twice composes
        # once.
        coreNames = builtins.attrNames coreOverlays;
        publishedNames = coreNames ++ [ "nixpkgs-lib" ];
        importedLibOverlays =
          builtins.map (name: registeredLibOverlays.${name}) coreNames
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
        # capture.  Checks belong to the export side (integrations),
        # not here.
        manifestOverlay = {
          imports = [ ];
          overlay = _final: prev: {
            caisson-core = (prev.caisson-core or { }) // {
              inherit configs;
              libManifest = {
                inherit
                  configs
                  defaultEcosystemSrc
                  inputs
                  namespace
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
        builtins.seq (builtins.isFunction rawConfigs || configs) (
          builtins.seq (builtins.isFunction rawLibOverlays || libOverlays) (
            builtins.seq (builtins.isAttrs rawEcosystems || defaultEcosystemSrc) (
              builtins.seq (builtins.isAttrs rawProjects || projects) (
                builtins.seq (rawSystems == null || builtins.isList rawSystems || systems) (
                  builtins.seq (rawNamespace == null || builtins.isString rawNamespace || namespace) finalLib
                )
              )
            )
          )
        )
      )
    );

in
{
  overlay = final: prev: {
    caisson-core = (prev.caisson-core or { }) // {
      inherit
        contributeClasses
        contributeModules
        coreEntries
        importApply
        mkExtendedLib
        mkLib
        mkNixpkgsLibEntry
        ;
      mkModule = mkModuleForComposition {
        inputs = closure-inputs;
        finalLib = final;
      };
      mkLibOverlay = mkLibOverlayFor {
        inputs = closure-inputs;
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
      # so the composing flake's own entries win over contributed
      # ones.
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
      # The manifest slots, one per evaluation phase: the lib (filled
      # by mkLib), the package set (filled on the lib inside a package
      # set) and the module evaluation (filled on the lib an
      # evaluation is built with). All three are present on every
      # composed library and null until filled.
      libManifest = (prev.caisson-core or { }).libManifest or null;
      pkgsManifest = (prev.caisson-core or { }).pkgsManifest or null;
      evalManifest = (prev.caisson-core or { }).evalManifest or null;
    };
  };
}
