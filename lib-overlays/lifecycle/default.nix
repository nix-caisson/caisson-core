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
#     `defaultEcosystemSrc.nixpkgs-lib` or `.nixpkgs`, or a pinned
#     source named exactly so, through `resolve`; a miss is null, and
#     the entry names the declaration only where it is composed.
#   - The `caisson-core` namespace is contributed by caisson-core's own
#     entries and nothing else.  The manifest (the capture of what
#     mkLib consumed) enters through composition as a synthetic final
#     overlay, the same channel as everything else.
#
# This overlay takes the bootstrap closure of caisson-core's own
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
  # identity the selection compares when one key is reached twice; an
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
  # a synthetic one derived from its importer's key and its position,
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
  # one key are refused rather than one silently winning. The result is
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
  # through `pkgs.lib`) carrying the phase slots, where the last
  # filled slot is the manifest.  Null when the value carries none.
  manifestOf =
    value:
    let
      isManifest = v: builtins.isAttrs v && (v._type or null) == "caisson-manifest";
      # The last filled of a composed lib's phase slots, or null.
      lastSlot =
        composed:
        let
          slots = composed.caisson-core;
        in
        if slots.evalManifest or null != null then
          slots.evalManifest
        else if slots.pkgsManifest or null != null then
          slots.pkgsManifest
        else
          slots.libManifest or null;
      candidates = [
        value
        (value.caisson.manifest or null)
        (value.config.caisson.manifest or null)
        (if builtins.isAttrs value && value ? caisson-core then lastSlot value else null)
        (if builtins.isAttrs value && value ? lib.caisson-core then lastSlot value.lib else null)
      ];
      found = builtins.filter isManifest candidates;
    in
    if found == [ ] then null else builtins.head found;

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
  # unexpected argument is Nix's own error at the call site, naming
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
      # The namespace this composition contributes to the composed
      # library, e.g. "my-project".
      namespace ? null,
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
      # Which registered overlays apply to this composition.
      libOverlayImports ? null,
      # `mkPkgOverlay: { <name> = entry; }`, usually mkPkgOverlays ./pkg-overlays:
      # the package overlays this tree registers, keyed entries whose
      # `overlay` is a nixpkgs overlay. Nothing here applies them; a
      # package set selects from the registry through pkgOverlaysFor.
      pkgOverlays ? null,
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

        rawModules = given "modules" (composedLib: { });
        rawConfigs = given "configs" (composedLib: { });
        rawLibOverlays = given "libOverlays" (mkLibOverlay: { });
        rawPkgOverlays = given "pkgOverlays" (mkPkgOverlay: { });
        libOverlayImports = given "libOverlayImports" (overlays: builtins.attrValues overlays);
        rawEcosystems = given "defaultEcosystemSrc" { };
        rawProjects = given "projects" { };
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
        # without a `/` is one of the project's own names and is keyed
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
        # part declared on its own, else the tree's nixpkgs (one pin
        # supplies every part), else a pinned source named exactly as
        # either; null when nothing declares it.
        nixpkgsLibSource =
          let
            # The plain function rather than the one in the composed
            # library: the source decides what the fixpoint holds, so
            # it cannot be read out of the fixpoint.
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
        # local registration, the project's name for a contributed one,
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

        # The same construction as the composition's own
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

        # caisson-core's own entries, bound to this composition.
        coreOverlays = coreEntries {
          inherit sources;
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
        #
        # Every entry records where it came from in `project`: the
        # consumed project's name for a contributed one, null for a
        # local registration, and `caisson-core` for the entries
        # caisson-core publishes into every composition, which this
        # composition did not register either. An export selector keeps
        # the local entries with a filter on `project == null`.
        registeredLibOverlays = builtins.mapAttrs (name: overlay: overlay // { key = name; }) (
          builtins.mapAttrs (_: overlay: overlay // { project = "caisson-core"; }) (
            coreOverlays
            // {
              nixpkgs-lib = mkNixpkgsLibEntry nixpkgsLibSource;
            }
          )
          // projectLibOverlays
          // builtins.mapAttrs (_: overlay: overlay // { project = null; }) libOverlays
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

        # Beside the module dictionary, per class and name, the project
        # a registered module came from: null for a local registration
        # (including one that shadows a project's entry of the same
        # name), the project's name otherwise. An export selector keeps
        # the local modules with a filter on this.
        registeredModuleProjects =
          projectModuleProjects
          // builtins.listToAttrs (
            builtins.map (class: {
              name = class;
              value =
                (projectModuleProjects.${class} or { }) // builtins.mapAttrs (_: _: null) modules.${class};
            }) (builtins.attrNames modules)
          );

        # The lib manifest: the capture of what mkLib consumed, filled
        # into the `libManifest` slot through composition like
        # everything else.  Its dictionaries are the registered ones
        # (project entries under `<project>/<name>`, locals winning a
        # name collision), so export selections drawn from the
        # manifest see project-borne entries exactly like
        # hand-registered ones; `projects` keeps the raw per-project
        # capture.  `sources` are the pinned sources with each pin
        # recorded against the root, and `root` the tree's identity.
        # `name` is the declared namespace, absent when none is
        # declared; `namespace` holds the same value (null when
        # undeclared) until caisson reads `name`. The lib mkLib returns is the full lib of a root
        # declaration, so it is not childless and its chain is empty:
        # no parent, no ancestors, nothing consumed, and no children
        # until package configs are built under it.  Checks belong to
        # the export side (integrations), not here.
        manifestOverlay = {
          imports = [ ];
          overlay = _final: prev: {
            caisson-core = (prev.caisson-core or { }) // {
              inherit configs;
              libManifest = {
                _type = "caisson-manifest";
                type = "lib";
                inherit
                  configs
                  defaultEcosystemSrc
                  entries
                  namespace
                  projects
                  root
                  systems
                  ;
                sources = recordedSources;
                libOverlays = registeredLibOverlays;
                modules = registeredModules;
                moduleProjects = registeredModuleProjects;
                pkgOverlays = registeredPkgOverlays;
                childless = false;
                inputs = [ ];
                parent = null;
                ancestors = [ ];
                nearest = { };
                children = { };
              }
              // (if namespace == null then { } else { name = namespace; });
            };
          };
        };

        published = builtins.listToAttrs (
          builtins.map (name: {
            inherit name;
            value = registeredLibOverlays.${name};
          }) publishedNames
        );

        # The manifest's `entries`: the selection's keys in composition
        # order, caisson-core's forced entries first. A key that names
        # no registry entry (a keyless import's synthesized key, or a
        # key an overlay built elsewhere carried in) is an ad hoc
        # entry and marked opaque, as is each keyless entry, which the
        # composition applies after the keyed ones. The walk is over
        # the selection alone: the registrations and the manifest
        # compose after it as caisson-core's own recording, not as
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

        finalLib =
          (composeRegistered { inherit published; } (
            importedLibOverlays
            ++ [
              projectModulesOverlay
              localModulesOverlay
              manifestOverlay
            ]
          )).lib;

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
        (builtins.isFunction rawPkgOverlays || localPkgOverlays)
        (builtins.isAttrs rawEcosystems || defaultEcosystemSrc)
        (builtins.isAttrs rawProjects || projects)
        (rawSystems == null || builtins.isList rawSystems || systems)
        (rawNamespace == null || builtins.isString rawNamespace || namespace)
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
        importApply
        manifestOf
        mkExtendedLib
        mkLib
        mkNixpkgsLibEntry
        pkgOverlaysFor
        ;
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
