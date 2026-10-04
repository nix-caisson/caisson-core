# SPDX-License-Identifier: MIT
#
# Hermetic tests: pure evaluation, no dependencies.  Run with
#
#   nix eval -f tests summary
#
# from the repository root.  `summary` throws (listing the failing
# case names) unless every case passes.

let

  core = import ../lib;
  inherit (core) compose resolve;

  entry = key: imports: overlay: { inherit key imports overlay; };

  base = entry "test.base" [ ] (
    _final: prev: {
      foo = "orig";
      applications = (prev.applications or 0) + 1;
    }
  );

  throws = expr: !(builtins.tryEval (builtins.deepSeq expr true)).success;

  # A stub integration's constructor, over the lib it is called
  # through: its evaluator applies `module` to the lib the evaluation
  # runs on, and it finalizes the configurations the module returns
  # under `children`, by integration and then name, against the
  # childless manifest.
  stubIntegration = stubIntegrationWith { };

  # The same constructor for an integration that evaluates a
  # configuration at a system.
  perSystemStubIntegration = stubIntegrationWith { perSystem = true; };

  stubIntegrationWith =
    declaration: type: lib: module:
    lib.caisson-core.mkConfiguration (
      declaration
      // {
        inherit type;
        evaluate = stubEvaluate module;
      }
    );

  stubEvaluate =
    module:
    { lib, manifest }:
    let
      config = module lib;
    in
    {
      value = {
        inherit config;
        seenLib = lib;
      };
      outputs.marker = config.marker or null;
      children = builtins.mapAttrs (
        integration:
        builtins.mapAttrs (
          name:
          lib.caisson-core.finalizeChild {
            inherit name;
            parent = manifest.childlessManifest;
            what = "`children.${integration}.${name}`";
          }
        )
      ) (config.children or { });
      forChildren = config.forChildren or { };
    };

  # The pin readers' pure parts, read directly.
  flakeLock = import ../lib-overlays/pins/flake-lock.nix;
  npinsData = import ../lib-overlays/pins/npins.nix;

  # The inputs a flake's `outputs` would receive, for the pins-flake
  # fixture: `self` points at its tree (whose flake.lock is read), and
  # each input carries what Nix puts on a resolved input.
  pinsFlakeInputs = rec {
    self = {
      outPath = ./fixtures/pins-flake;
      rev = "0000000000000000000000000000000000000abc";
      shortRev = "0000000";
      lastModified = 1;
      lastModifiedDate = "19700101000001";
      narHash = "sha256-SELF";
    };
    nixpkgs = {
      outPath = "/nix/store/00000000000000000000000000000000-source";
      rev = "1111111111111111111111111111111111111111";
      narHash = "sha256-NIXPKGS";
      lastModified = 10;
      lib = "nixpkgs-lib-marker";
    };
    follower = nixpkgs;
    nonflake = {
      outPath = "/nix/store/11111111111111111111111111111111-source";
      rev = "2222222222222222222222222222222222222222";
      narHash = "sha256-NONFLAKE";
      lastModified = 20;
    };
    overridden = {
      outPath = "/nix/store/22222222222222222222222222222222-source";
      narHash = "sha256-OVERRIDE";
      lastModified = 31;
    };
    unlocked = {
      outPath = "/nix/store/33333333333333333333333333333333-source";
    };
  };

  # The registry names of caisson-core's entries, present in every
  # mkLib composition.
  coreNames = [
    "caisson-core/compose"
    "caisson-core/kernel"
    "caisson-core/lifecycle"
    "caisson-core/pins"
    "caisson-core/readers"
    "caisson-core/resolve"
  ];

  # An overlay declaring the classes the modules-dir fixture holds
  # besides `generic`, which caisson-core declares itself.
  declaringClasses =
    { contributeClasses, mkModule, ... }:
    {
      overlay =
        _final: prev:
        contributeClasses prev {
          flake = {
            integration = "test-flake";
            mkModule = mkModule "flake";
          };
          structural = {
            integration = "test-structural";
            mkModule = mkModule "structural";
          };
        };
    };

  # Apply a list of nixpkgs overlays to an empty stand-in package set,
  # as a package set would: a fixpoint folded in order.
  applyPkgOverlays =
    overlays:
    let
      fixed =
        f:
        let
          x = f x;
        in
        x;
    in
    fixed (
      builtins.foldl' (
        f: overlay: final:
        let
          prev = f final;
        in
        prev // overlay final prev
      ) (_final: { }) overlays
    );

  # A tree registering package overlays from a directory, and a tree
  # consuming it as a project beside a local entry that imports the
  # project's default entry through the consumer's registry.
  pkgOverlayProducer = core.mkLib {
    sources = { };
    pkgOverlays = lib: lib.caisson-core.mkPkgOverlays ./fixtures/pkg-overlays-dir;
  };
  pkgOverlayConsumer = core.mkLib {
    sources = { };
    projects.producer.pkgOverlays = pkgOverlayProducer.caisson-core.libManifest.pkgOverlays;
    pkgOverlays = lib: {
      local = lib.caisson-core.mkPkgOverlay (
        { closure-lib, ... }:
        {
          imports = [ closure-lib.caisson-core.libManifest.pkgOverlays."producer/default" ];
          overlay = _final: prev: { local = prev.base + "+local"; };
        }
      );
    };
  };

  results = {

    unionOfContributions =
      let
        a = entry "test.a" [ ] (_final: _prev: { x = 1; });
        b = entry "test.b" [ ] (_final: _prev: { y = 2; });
        r = compose {
          entries = [
            a
            b
          ];
        };
      in
      r.lib.x == 1 && r.lib.y == 2;

    finalSeesFixpointRegardlessOfOrder =
      let
        a = entry "test.a" [ ] (_final: _prev: { x = 1; });
        b = entry "test.b" [ ] (final: _prev: { y = final.x + 1; });
        r = compose {
          entries = [
            b
            a
          ];
        };
      in
      r.lib.y == 2;

    dedupDiamondAppliesOnce =
      let
        a = entry "test.a" [ base ] (_final: _prev: { x = 1; });
        b = entry "test.b" [ base ] (_final: _prev: { y = 2; });
        r = compose {
          entries = [
            a
            b
          ];
        };
      in
      r.lib.applications == 1;

    lastWinsValueFirstWinsPosition =
      let
        v1 = entry "test.k" [ ] (_final: _prev: { v = 1; });
        other = entry "test.other" [ ] (_final: _prev: { o = true; });
        v2 = entry "test.k" [ ] (_final: _prev: { v = 2; });
        r = compose {
          entries = [
            v1
            other
            v2
          ];
        };
      in
      r.lib.v == 2
      &&
        r.meta.order == [
          "test.k"
          "test.other"
        ];

    polyfillSeesTargetAndWins =
      let
        polyfill = entry "test.polyfill" [ base ] (
          _final: prev: { foo = "patched-${prev.foo or "missing"}"; }
        );
        r = compose { entries = [ polyfill ]; };
      in
      r.lib.foo == "patched-orig";

    replacementInheritsPosition =
      let
        k1 = entry "test.k" [ ] (
          _final: prev: {
            sawN = prev ? n;
            v = 1;
          }
        );
        n = entry "test.n" [ ] (_final: _prev: { n = true; });
        k2 = entry "test.k" [ n ] (
          _final: prev: {
            sawN = prev ? n;
            v = 2;
          }
        );
        r = compose {
          entries = [
            k1
            k2
          ];
        };
      in
      r.lib.v == 2
      && r.lib.n
      && !r.lib.sawN
      &&
        r.meta.order == [
          "test.k"
          "test.n"
        ];

    cycleTerminatesDeterministically =
      let
        a = entry "test.ca" [ b ] (_final: _prev: { ca = true; });
        b = entry "test.cb" [ a ] (_final: _prev: { cb = true; });
        r = compose { entries = [ a ]; };
      in
      r.lib.ca
      && r.lib.cb
      &&
        r.meta.order == [
          "test.cb"
          "test.ca"
        ];

    keylessAppliesAfterKeyedWorld =
      let
        keyed = entry "test.keyed" [ ] (_final: _prev: { fromKeyed = true; });
        anon = {
          key = null;
          imports = [ ];
          overlay = _final: prev: { anonSawKeyed = prev ? fromKeyed; };
        };
        r = compose {
          entries = [
            anon
            keyed
          ];
        };
      in
      r.lib.anonSawKeyed && r.meta.tailLength == 1;

    keylessStacksOnRepetition =
      let
        anon = {
          key = null;
          imports = [ ];
          overlay = _final: prev: { count = (prev.count or 0) + 1; };
        };
        r = compose {
          entries = [
            anon
            anon
          ];
        };
      in
      r.lib.count == 2 && r.meta.tailLength == 2;

    keylessMayImportKeyedForReachability =
      let
        anon = {
          key = null;
          imports = [ base ];
          overlay = _final: prev: { foo = "anon-${prev.foo}"; };
        };
        r = compose { entries = [ anon ]; };
      in
      r.lib.foo == "anon-orig";

    keylessCannotBeImported =
      let
        anon = {
          key = null;
          imports = [ ];
          overlay = _final: _prev: { };
        };
        importer = entry "test.importer" [ anon ] (_final: _prev: { });
      in
      throws (compose { entries = [ importer ]; }).meta.order;

    entryValidationThrows = throws (compose { entries = [ { key = "test.k"; } ]; }).meta.order;

    resolveExplicitWins =
      resolve {
        name = "nixpkgs-lib";
        explicit = "E";
        defaults.nixpkgs-lib = "D";
        sources.nixpkgs-lib = "S";
      } == "E";

    resolveDefaultBeatsSource =
      resolve {
        name = "nixpkgs-lib";
        defaults.nixpkgs-lib = "D";
        sources.nixpkgs-lib = "S";
      } == "D";

    resolveSourceByExactName =
      resolve {
        name = "nixpkgs-lib";
        sources = {
          nixpkgs-lib = "S";
          nixpkgs = "wrong";
        };
      } == "S";

    resolveMissIsNull = resolve { name = "nixpkgs-lib"; } == null;

    callFlakeWiresInputsAndSelf =
      let
        wired = core.callFlake {
          src = ./fixtures/hello-flake;
          inputs.greeting = {
            text = "hello";
          };
          sourceInfo.rev = "fixture";
        };
      in
      wired.message == "hello, kernel"
      && wired.viaSelf == "hello, kernel"
      && wired.selfPath == ./fixtures/hello-flake
      && wired.rev == "fixture"
      && wired._type == "flake"
      && wired.inputs.greeting.text == "hello";

    # A lockfile'd flake with no inputs has no sources.
    pinsFlakeCompatNoInputs = (core.pins.flake-compat ./fixtures/deps-flake).sources == { };

    # Lifecycle: mkLib and the registration machinery.

    # mkLib's signature is its pattern, read back as data: `sources` is
    # required, `root` and the rest are optional, and `inputs` and the
    # old `ecosystems` are not arguments, so Nix refuses them at the
    # call site (an error `tryEval` cannot catch, which is why the
    # pattern is what is tested). A `sources` of the wrong type is
    # caisson-core's refusal.
    lifecycleMkLibSignature =
      builtins.functionArgs core.mkLib == {
        sources = false;
        root = true;
        name = true;
        systems = true;
        defaultEcosystemSrc = true;
        projects = true;
        modules = true;
        configs = true;
        libOverlays = true;
        libOverlayImports = true;
        extraLibOverlayImports = true;
        pkgOverlays = true;
        pkgSets = true;
      }
      && throws (core.mkLib { sources = [ ]; });

    lifecycleMkLibRootShape =
      (core.mkLib { sources = { }; }).caisson-core.libManifest.root == null
      && throws (
        core.mkLib {
          sources = { };
          root = { };
        }
      ).caisson-core.libManifest
      && throws (
        core.mkLib {
          sources = { };
          root = "x";
        }
      ).caisson-core.libManifest;

    # A registered overlay's keyless imports still apply before it,
    # and before the overlay that imports the importer.
    lifecycleKeylessImportsApplyBeforeTheirImporter =
      let
        deeper = {
          imports = [ ];
          overlay = _final: _prev: { deeper = "d"; };
        };
        deep = {
          imports = [ deeper ];
          overlay = _final: prev: { deep = prev.deeper + "e"; };
        };
        composed = core.mkLib {
          sources = { };
          libOverlays = lib: {
            main = lib.caisson-core.mkLibOverlay (
              { ... }:
              {
                imports = [ deep ];
                overlay = _final: prev: {
                  sawDeep = prev.deep;
                  sawDeeper = prev.deeper;
                };
              }
            );
          };
        };
      in
      composed.sawDeep == "de" && composed.sawDeeper == "d";

    # Nothing is composed over: a composition with no source declared
    # is a bare library that composes fine until something imports the
    # nixpkgs-lib entry.
    lifecycleBareCompositionNeedsNoSource =
      let
        composed = core.mkLib { sources = { }; };
      in
      builtins.isAttrs composed.caisson-core.libManifest && !(composed ? extend);

    lifecycleComposesOverlays =
      let
        composed = core.mkLib {
          sources = { };
          libOverlays = lib: {
            a-base = lib.caisson-core.mkLibOverlay ({ ... }: { overlay = _final: _prev: { marker = 1; }; });
            b = lib.caisson-core.mkLibOverlay (
              { ... }:
              {
                overlay = _final: prev: { x = prev.marker + 1; };
              }
            );
          };
        };
      in
      composed.marker == 1 && composed.x == 2;

    # The nixpkgs-lib entry: composed where an overlay imports it,
    # from the declared source, as that source fixes it: a later
    # overlay's definition is seen by readers of the composed lib and
    # not by the upstream function that reads the name internally.
    lifecycleNixpkgsLibEntryComposesFromTheDeclaredSource =
      let
        composed = core.mkLib {
          sources = { };
          defaultEcosystemSrc.nixpkgs-lib = ./fixtures/nixpkgs-lib-stub;
          libOverlays = lib: {
            probe = lib.caisson-core.mkLibOverlay (
              { entries, ... }:
              {
                imports = [ entries.nixpkgs-lib ];
                overlay = final: _prev: {
                  viaUpstream = final.stubIncrement 1;
                  stubIncrement = n: n + 100;
                };
              }
            );
          };
        };
      in
      composed.viaUpstream == 101 && composed.stubReadsSelf == 11 && composed ? extend;

    lifecycleNixpkgsLibEntryDerivesFromTheNixpkgsSource =
      let
        composed = core.mkLib {
          sources = { };
          defaultEcosystemSrc.nixpkgs = ./fixtures/nixpkgs-lib-stub;
          libOverlays = lib: {
            probe = lib.caisson-core.mkLibOverlay (
              { entries, ... }:
              {
                imports = [ entries.nixpkgs-lib ];
                overlay = _final: _prev: { };
              }
            );
          };
        };
      in
      composed.stubIncrement 1 == 2;

    lifecycleNixpkgsLibEntryFailsOnlyWhereImported =
      throws
        (core.mkLib {
          sources = { };
          libOverlays = lib: {
            probe = lib.caisson-core.mkLibOverlay (
              { entries, ... }:
              {
                imports = [ entries.nixpkgs-lib ];
                overlay = _final: _prev: { };
              }
            );
          };
        }).stubIncrement;

    # An overlay built in another tree imports that tree's nixpkgs-lib
    # entry as a value; composed here, the import is read by key from
    # this tree's registry, so the other tree's source does not leak in.
    lifecycleImportedPublishedEntriesResolveByKeyHere =
      let
        otherTree = core.mkLib {
          sources = { };
          defaultEcosystemSrc.nixpkgs-lib = ./fixtures/nixpkgs-lib-stub;
          libOverlays = lib: {
            exported = lib.caisson-core.mkLibOverlay (
              { entries, ... }:
              {
                imports = [ entries.nixpkgs-lib ];
                overlay = final: _prev: { viaUpstream = final.stubIncrement 1; };
              }
            );
          };
        };
        here = core.mkLib {
          sources = { };
          libOverlays = lib: {
            nixpkgs-lib = lib.caisson-core.mkLibOverlay ({ ... }: { overlay = _final: _prev: { stubIncrement = n: n * 3; }; });
            borrowed = otherTree.caisson-core.libManifest.libOverlays.exported;
          };
        };
      in
      otherTree.viaUpstream == 2 && here.viaUpstream == 3;

    # Two projects each exporting an overlay registered as `default`
    # both compose here: the compose key is the registry name in this
    # tree, not the key the overlay carried from the tree that built it.
    lifecycleProjectOverlaysKeepTheirRegistryNames =
      let
        project =
          marker:
          (core.mkLib {
            sources = { };
            libOverlays = lib: {
              default = lib.caisson-core.mkLibOverlay ({ ... }: { overlay = _final: _prev: { ${marker} = true; }; });
            };
          }).caisson-core.libManifest.libOverlays;
        composed = core.mkLib {
          sources = { };
          projects = {
            a = {
              libOverlays = {
                inherit (project "fromA") default;
              };
            };
            b = {
              libOverlays = {
                inherit (project "fromB") default;
              };
            };
          };
        };
      in
      composed.fromA && composed.fromB;

    # Registering under a published name replaces the entry for every
    # importer.
    lifecycleRegistrationReplacesThePublishedEntry =
      let
        composed = core.mkLib {
          sources = { };
          libOverlays = lib: {
            nixpkgs-lib = lib.caisson-core.mkLibOverlay ({ ... }: { overlay = _final: _prev: { stubIncrement = n: n * 3; }; });
            probe = lib.caisson-core.mkLibOverlay (
              { entries, ... }:
              {
                imports = [ entries.nixpkgs-lib ];
                overlay = final: _prev: { viaUpstream = final.stubIncrement 2; };
              }
            );
          };
        };
      in
      composed.viaUpstream == 6
      &&
        builtins.attrNames composed.caisson-core.libManifest.libOverlays == coreNames
        ++ [
          "nixpkgs-lib"
          "probe"
        ];

    # `closure-inputs` is the composition's pinned sources.
    lifecycleOverlayClosureCarriesSources =
      let
        composed = core.mkLib {
          sources = {
            probe = 42;
          };
          libOverlays = lib: {
            a = lib.caisson-core.mkLibOverlay (
              { closure-inputs, ... }:
              {
                overlay = _final: _prev: { seen = closure-inputs.probe; };
              }
            );
          };
        };
      in
      composed.seen == 42;

    lifecycleInjectsMachinery =
      let
        composed = core.mkLib {
          sources = { };
        };
      in
      builtins.isFunction composed.caisson-core.mkLib
      && builtins.isFunction composed.caisson-core.mkLibOverlay
      && builtins.isFunction (composed.caisson-core.mkModule "nixos")
      && builtins.isFunction composed.caisson-core.importApply
      && builtins.isFunction composed.caisson-core.compose
      && builtins.isFunction composed.caisson-core.resolve
      && builtins.isFunction composed.caisson-core.callFlake
      && builtins.isFunction composed.caisson-core.callConsumerFlake
      && !(composed.caisson-core ? partitionExtraInputs)
      && builtins.isFunction composed.caisson-core.pins.flake-compat
      && builtins.isFunction composed.caisson-core.mkModules
      && builtins.isFunction composed.caisson-core.mkLibOverlays
      && builtins.isFunction composed.caisson-core.mkPkgOverlay
      && builtins.isFunction composed.caisson-core.mkPkgOverlays
      && builtins.isFunction composed.caisson-core.pkgOverlaysFor
      && composed.caisson-core.modules == { };

    lifecycleOverlayClosureCarriesLib =
      let
        composed = core.mkLib {
          sources = { };
          libOverlays = lib: {
            marker = lib.caisson-core.mkLibOverlay ({ ... }: { overlay = _final: _prev: { marker = "composed"; }; });
            probe = lib.caisson-core.mkLibOverlay (
              { closure-lib, ... }:
              {
                overlay = _final: _prev: { probe = closure-lib.marker; };
              }
            );
          };
        };
      in
      composed.probe == "composed";

    readersMkModulesReadsClassDirectories =
      let
        composed = core.mkLib {
          sources = { };
          modules = lib: lib.caisson-core.mkModules ./fixtures/modules-dir;
          libOverlays = lib: { classes = lib.caisson-core.mkLibOverlay declaringClasses; };
        };
        registry = composed.caisson-core.modules;
        origin = m: (builtins.head m.imports).config.origin;
      in
      builtins.attrNames registry == [
        "flake"
        "generic"
        "structural"
      ]
      && origin registry.flake.default == "flake-default"
      && origin registry.generic.core == "generic-core"
      # A symlinked entry registers under the class it sits in.
      && origin registry.structural.core == "generic-core"
      && registry.structural.core.key == builtins.toString ./fixtures/modules-dir/structural/core
      && composed.caisson-core.classes.generic.integration == "caisson-core";

    readersMkModulesRegistersConfigs =
      let
        composed = core.mkLib {
          sources = { };
          configs = lib: lib.caisson-core.mkModules ./fixtures/modules-dir;
          libOverlays = lib: { classes = lib.caisson-core.mkLibOverlay declaringClasses; };
        };
      in
      (builtins.head composed.caisson-core.configs.flake.default.imports).config.origin
      == "flake-default";

    # The reader registers through the index, so an integration that
    # declares a class again, composed later, wraps every module of
    # the class.
    readersMkModulesRegistersThroughTheClassIndex =
      let
        wrapping =
          { contributeClasses, mkModule, ... }:
          {
            overlay =
              _final: prev:
              contributeClasses prev {
                flake = {
                  integration = "wrapper";
                  mkModule = path: {
                    wrapped = mkModule "flake" path;
                  };
                };
              };
          };
        composed = core.mkLib {
          sources = { };
          modules = lib: lib.caisson-core.mkModules ./fixtures/modules-dir;
          libOverlays = lib: {
            classes = lib.caisson-core.mkLibOverlay declaringClasses;
            wrapper = lib.caisson-core.mkLibOverlay wrapping;
          };
          libOverlayImports = lib: [
            lib.caisson-core.nixpkgs-lib.overlays.classes
            lib.caisson-core.nixpkgs-lib.overlays.wrapper
          ];
        };
      in
      composed.caisson-core.classes.flake.integration == "wrapper"
      &&
        (builtins.head composed.caisson-core.modules.flake.default.wrapped.imports).config.origin
        == "flake-default";

    readersMkModulesRefusesAnUndeclaredClass =
      throws
        (core.mkLib {
          sources = { };
          modules = lib: lib.caisson-core.mkModules ./fixtures/modules-dir;
        }).caisson-core.modules.flake;

    # The refusals are read from a library that declares the class of
    # the fixture, so what throws is the directory and not the class.
    readersMkModulesRefusesAStrayFile =
      let
        composed = core.mkLib {
          sources = { };
          libOverlays = lib: { classes = lib.caisson-core.mkLibOverlay declaringClasses; };
        };
      in
      builtins.isAttrs (composed.caisson-core.mkModules ./fixtures/modules-dir)
      && throws (composed.caisson-core.mkModules ./fixtures/modules-dir-stray);

    readersMkModulesRefusesAnEntryWithoutDefault =
      let
        composed = core.mkLib {
          sources = { };
          libOverlays = lib: { classes = lib.caisson-core.mkLibOverlay declaringClasses; };
        };
      in
      throws (composed.caisson-core.mkModules ./fixtures/modules-dir-empty-entry);

    readersMkLibOverlaysReadsEntries =
      let
        composed = core.mkLib {
          sources = { };
          libOverlays = lib: lib.caisson-core.mkLibOverlays ./fixtures/lib-overlays-dir;
        };
      in
      composed.fromDefault
      && composed.fromExtra
      &&
        builtins.attrNames composed.caisson-core.libManifest.libOverlays == coreNames
        ++ [
          "default"
          "extra"
          "nixpkgs-lib"
        ];

    readersMkLibOverlaysRefusesAStrayFile = throws (
      core.mkLibOverlays ./fixtures/lib-overlays-dir-stray
    );

    # Package overlays: registered in mkLib beside libOverlays, keyed by
    # registry name, recorded in the manifest, applied by nothing here.
    pkgOverlaysRegisterFromAFunction =
      let
        composed = core.mkLib {
          sources = { };
          pkgOverlays = lib: {
            hello = lib.caisson-core.mkPkgOverlay ({ ... }: { overlay = _final: _prev: { hello = "hi"; }; });
          };
        };
        entry = composed.caisson-core.libManifest.pkgOverlays.hello;
      in
      entry.key == "hello"
      && entry.origin == null
      && entry.project == null
      && entry.imports == [ ]
      && (applyPkgOverlays (composed.caisson-core.pkgOverlaysFor [ entry ])).hello == "hi"
      && (core.mkLib { sources = { }; }).caisson-core.libManifest.pkgOverlays == { };

    pkgOverlaysRefuseNonFunction =
      !(builtins.tryEval (
        builtins.seq (core.mkLib {
          sources = { };
          pkgOverlays = { };
        }) true
      )).success;

    readersMkPkgOverlaysReadsEntries =
      let
        registry = pkgOverlayProducer.caisson-core.libManifest.pkgOverlays;
        applied = applyPkgOverlays (core.pkgOverlaysFor [ registry.default ]);
      in
      builtins.attrNames registry == [
        "default"
        "extra"
      ]
      && registry.default.origin == toString ./fixtures/pkg-overlays-dir/default
      && builtins.map (i: i.key) registry.default.imports == [ "extra" ]
      # The import is applied before its importer.
      && applied.base == "extra+base";

    readersMkPkgOverlaysRefusesAStrayFile = throws (
      core.mkPkgOverlays ./fixtures/lib-overlays-dir-stray
    );

    # A consumed project's entries join under `<project>/<name>`, their
    # imports of siblings rekeyed with them, and each records the project.
    pkgOverlaysFromProjects =
      let
        registry = pkgOverlayConsumer.caisson-core.libManifest.pkgOverlays;
      in
      builtins.attrNames registry == [
        "local"
        "producer/default"
        "producer/extra"
      ]
      && builtins.map (i: i.key) registry."producer/default".imports == [ "producer/extra" ]
      && registry."producer/default".project == "producer"
      && (builtins.head registry."producer/default".imports).project == "producer"
      && registry.local.project == null;

    # The local view an export selector keeps: entries whose `project`
    # is null.
    pkgOverlaysLocalView =
      let
        registry = pkgOverlayConsumer.caisson-core.libManifest.pkgOverlays;
      in
      builtins.filter (name: registry.${name}.project == null) (builtins.attrNames registry) == [
        "local"
      ];

    # Imports first, each key once: the sibling a selected entry imports
    # is applied once even when it is selected as well.
    pkgOverlaysForOrdersImportsFirstAndDeduplicates =
      let
        registry = pkgOverlayConsumer.caisson-core.libManifest.pkgOverlays;
        overlays = core.pkgOverlaysFor [
          registry."producer/default"
          registry."producer/extra"
          registry.local
        ];
        applied = applyPkgOverlays overlays;
      in
      builtins.length overlays == 3 && applied.base == "extra+base" && applied.local == "extra+base+local";

    # One key reached through two imports, with one origin, is one entry.
    pkgOverlaysForDeduplicatesAcrossImporters =
      let
        shared = {
          key = "shared";
          origin = "/shared";
          overlay = _final: prev: { count = (prev.count or 0) + 1; };
        };
        a = {
          key = "a";
          imports = [ shared ];
          overlay = _final: _prev: { };
        };
        b = {
          key = "b";
          imports = [ (shared // { imports = [ ]; }) ];
          overlay = _final: _prev: { };
        };
      in
      (applyPkgOverlays (core.pkgOverlaysFor [
        a
        b
      ])).count == 1;

    # Two different entries under one key are refused.
    pkgOverlaysForRefusesTwoEntriesUnderOneKey =
      let
        shared = origin: {
          key = "shared";
          inherit origin;
          overlay = _final: _prev: { };
        };
      in
      throws (
        core.pkgOverlaysFor [
          {
            key = "a";
            imports = [ (shared "/one") ];
            overlay = _final: _prev: { };
          }
          {
            key = "b";
            imports = [ (shared "/two") ];
            overlay = _final: _prev: { };
          }
        ]
      )
      && throws (core.pkgOverlaysFor [ { overlay = _final: _prev: { }; } ]);

    lifecycleLocalModulesRegister =
      let
        composed = core.mkLib {
          sources = { };
          modules = composedLib: {
            nixos.local = composedLib.caisson-core.mkModule "nixos" ({ ... }: { config.origin = "local"; });
          };
        };
      in
      composed.caisson-core.modules.nixos.local.config.origin == "local";

    lifecycleConfigsRegister =
      let
        composed = core.mkLib {
          sources = { };
          configs = composedLib: {
            structural.top = composedLib.caisson-core.mkModule "structural" (
              { ... }: { config.origin = "top"; }
            );
          };
        };
      in
      composed.caisson-core.configs.structural.top.config.origin == "top"
      && composed.caisson-core.libManifest.configs.structural.top.config.origin == "top"
      && (core.mkLib { sources = { }; }).caisson-core.configs == { };

    lifecycleConfigsRefusesNonFunction =
      !(builtins.tryEval (
        builtins.seq (core.mkLib {
          sources = { };
          configs = { };
        }) true
      )).success;

    lifecycleOverlayContributionsMergeAndLocalsWin =
      let
        contributor =
          { mkModule, contributeModules, ... }:
          {
            overlay =
              _final: prev:
              contributeModules prev {
                nixos = {
                  "other/contributed" = mkModule "nixos" ({ ... }: { config.origin = "contributed"; });
                  shared = mkModule "nixos" ({ ... }: { config.origin = "contributed"; });
                };
              };
          };
        composed = core.mkLib {
          sources = { };
          modules = composedLib: {
            nixos.shared = composedLib.caisson-core.mkModule "nixos" ({ ... }: { config.origin = "local"; });
          };
          libOverlays = lib: { c = lib.caisson-core.mkLibOverlay contributor; };
        };
        registry = composed.caisson-core.modules.nixos;
      in
      registry."other/contributed".config.origin == "contributed"
      && registry.shared.config.origin == "local";

    lifecycleManifestCapturesMkLibFacts =
      let
        theSources = {
          probe = {
            outPath = ./fixtures/pins-plain-dir;
          };
        };
        theRoot = {
          outPath = ./fixtures;
          dirty = false;
        };
        composed = core.mkLib {
          sources = theSources;
          root = theRoot;
          modules = composedLib: {
            nixos.local = composedLib.caisson-core.mkModule "nixos" ({ ... }: { config.origin = "local"; });
          };
          libOverlays = lib: {
            a = lib.caisson-core.mkLibOverlay ({ ... }: { overlay = _final: _prev: { }; });
          };
        };
        manifest = composed.caisson-core.libManifest;
      in
      builtins.attrNames manifest == [
        "_type"
        "ancestors"
        "childless"
        "children"
        "configs"
        "defaultEcosystemSrc"
        "entries"
        "history"
        "inputs"
        "libOverlays"
        "moduleProjects"
        "modules"
        "nearest"
        "parent"
        "pkgOverlays"
        "pkgSets"
        "projects"
        "root"
        "sources"
        "systems"
        "type"
      ]
      && manifest.type == "lib"
      && manifest.pkgSets == { }
      && manifest.childless == false
      && manifest.inputs == [ ]
      && manifest.parent == null
      && manifest.ancestors == [ ]
      && manifest.nearest == { }
      && manifest.children == { }
      && manifest.pkgOverlays == { }
      && manifest.sources == theSources
      && manifest.root == theRoot
      && manifest.defaultEcosystemSrc == { }
      && manifest.systems == null
      && builtins.attrNames manifest.libOverlays == [ "a" ] ++ coreNames ++ [ "nixpkgs-lib" ]
      && builtins.attrNames manifest.modules == [ "nixos" ]
      && manifest.modules.nixos.local.config.origin == "local";

    # The phase manifests are present on every composed library;
    # mkLib fills in the lib manifest and leaves the others null.
    lifecyclePhaseManifestsArePresentAndNullUntilFilledIn =
      let
        composed = core.mkLib {
          sources = { };
        };
      in
      builtins.isAttrs composed.caisson-core.libManifest
      && composed.caisson-core.pkgsManifest == null
      && composed.caisson-core.evalManifest == null;

    # manifestOf finds the manifest in each shape a file may return,
    # and null where the value carries none.
    lifecycleManifestOfFindsTheManifest =
      let
        inherit (core) manifestOf;
        composed = core.mkLib {
          sources = { };
          name = "probe";
        };
        libManifest = composed.caisson-core.libManifest;
        # A lib with a later phase manifest filled in, as a package set's or an
        # evaluation's lib carries it.
        withPhase =
          attr: tag:
          composed
          // {
            caisson-core = composed.caisson-core // {
              ${attr} = {
                _type = "caisson-manifest";
                inherit tag;
              };
            };
          };
      in
      libManifest._type == "caisson-manifest"
      && manifestOf libManifest == libManifest
      && manifestOf composed == libManifest
      && manifestOf { lib = composed; } == libManifest
      && manifestOf { caisson.manifest = libManifest; } == libManifest
      && manifestOf { config.caisson.manifest = libManifest; } == libManifest
      && (manifestOf (withPhase "pkgsManifest" "pkgs")).tag == "pkgs"
      && (manifestOf { lib = withPhase "pkgsManifest" "pkgs"; }).tag == "pkgs"
      && (manifestOf (withPhase "evalManifest" "eval")).tag == "eval"
      && manifestOf { } == null
      && manifestOf { caisson.manifest = { }; } == null
      && manifestOf { config = 1; } == null
      && manifestOf "a string" == null;

    lifecycleSystemsAreDeclaredOnMkLib =
      let
        composed = core.mkLib {
          sources = { };
          systems = [
            "x86_64-linux"
            "aarch64-linux"
          ];
        };
      in
      composed.caisson-core.libManifest.systems == [
        "x86_64-linux"
        "aarch64-linux"
      ];

    lifecycleSystemsMustBeAListOfStrings =
      throws (
        core.mkLib {
          sources = { };
          systems = "x86_64-linux";
        }
      )
      && throws (
        core.mkLib {
          sources = { };
          systems = [ 1 ];
        }
      );

    # The project's name is declared on mkLib and recorded as
    # `name` in the root lib manifest.
    lifecycleNameIsDeclaredOnMkLib =
      let
        composed = core.mkLib {
          sources = { };
          name = "my-project";
        };
      in
      composed.caisson-core.libManifest.name == "my-project";

    lifecycleNameIsAbsentWhenUndeclared =
      let
        composed = core.mkLib {
          sources = { };
        };
      in
      !(composed.caisson-core.libManifest ? name);

    # `entries` lists the selection's keys in composition order:
    # caisson-core's forced entries first, then the selected entries
    # with each entry's imports before it. A key that names no registry
    # entry is opaque.
    lifecycleManifestEntriesFollowCompositionOrder =
      let
        adHoc = {
          key = "ad-hoc";
          imports = [ ];
          overlay = _final: _prev: { };
        };
        composed = core.mkLib {
          sources = { };
          libOverlays = lib: {
            base = lib.caisson-core.mkLibOverlay ({ ... }: { overlay = _final: _prev: { }; });
            top = lib.caisson-core.mkLibOverlay (
              { ... }:
              {
                imports = [ adHoc ];
                overlay = _final: _prev: { };
              }
            );
          };
          libOverlayImports = lib: [
            lib.caisson-core.nixpkgs-lib.overlays.top
            lib.caisson-core.nixpkgs-lib.overlays.base
          ];
        };
        entries = composed.caisson-core.libManifest.entries;
      in
      builtins.map (e: e.key) entries == coreNames ++ [
        "ad-hoc"
        "top"
        "base"
      ]
      && builtins.map (e: e.opaque) entries
      == builtins.map (_: false) coreNames
      ++ [
        true
        false
        false
      ];

    # `history` records the forced entries as layers and the lib overlay
    # registrations grafted onto them (the core stage), then one layer
    # per selected entry in composition order (the bootstrap stage),
    # then the module registrations (the full stage), each indexed
    # within its operation and carrying its origin.
    lifecycleHistoryRecordsRegistrationsAndLayers =
      let
        composed = core.mkLib {
          sources = { };
          name = "probe-project";
          libOverlays = lib: {
            base = lib.caisson-core.mkLibOverlay ./fixtures/history-overlays/base;
            top = lib.caisson-core.mkLibOverlay ./fixtures/history-overlays/top;
          };
          libOverlayImports = lib: [
            lib.caisson-core.nixpkgs-lib.overlays.base
            lib.caisson-core.nixpkgs-lib.overlays.top
          ];
          modules = composedLib: {
            nixos.local = composedLib.caisson-core.mkModule "nixos" ({ ... }: { });
          };
        };
        manifest = composed.caisson-core.libManifest;
        history = manifest.history;
        ofOperation = operation: builtins.filter (e: e.operation == operation) history;
        layer = key: builtins.head (builtins.filter (e: e.operation == "layer" && e.key == key) (ofOperation "layer"));
      in
      builtins.map (e: "${e.operation}:${e.key}") history
      ==
        builtins.map (k: "layer:${k}") coreNames
        ++ builtins.map (n: "registry:libOverlays.${n}") (builtins.attrNames manifest.libOverlays)
        ++ [
          "layer:base"
          "layer:top"
          "registry:modules.nixos.local"
        ]
      && builtins.all (e: e.manifest == [ ] && e.type == "lib") history
      && builtins.map (e: e.index) (ofOperation "layer")
      == builtins.genList (i: i) (builtins.length (ofOperation "layer"))
      && builtins.map (e: e.index) (ofOperation "registry")
      == builtins.genList (i: i) (builtins.length (ofOperation "registry"))
      && (layer "base").origin == {
        project = "probe-project";
        file = toString ./fixtures/history-overlays/base;
      }
      && (layer "caisson-core/lifecycle").origin.project == "caisson-core";

    # `nixpkgs-lib.overlays` is the lib overlay registry at the lib it
    # is read from: the registry on that lib's manifest, published and
    # consumed entries included, at the core stage (where a selection
    # reads it) and in the returned lib alike, and empty in a library
    # no mkLib built.
    lifecycleLibOverlaysViewIsTheRegistry =
      let
        composed = core.mkLib {
          sources = { };
          libOverlays = lib: {
            base = lib.caisson-core.mkLibOverlay ./fixtures/history-overlays/base;
          };
          libOverlayImports = lib: [
            lib.caisson-core.nixpkgs-lib.overlays.base
            {
              imports = [ ];
              overlay = _final: _prev: { coreSeen = lib; };
            }
          ];
        };
        names = set: builtins.attrNames set;
      in
      names composed.caisson-core.nixpkgs-lib.overlays == names composed.caisson-core.libManifest.libOverlays
      && composed.caisson-core.nixpkgs-lib.overlays ? base
      && composed.caisson-core.nixpkgs-lib.overlays ? nixpkgs-lib
      && names composed.coreSeen.caisson-core.nixpkgs-lib.overlays
      == names composed.caisson-core.libManifest.libOverlays
      && composed.caisson-core.nixpkgs-lib.overlays.base.key == "base"
      && core.nixpkgs-lib.overlays == { };

    # The lib is built in stages, each carrying a manifest.
    # The core lib, which `libOverlayImports` receives, holds the forced
    # entries and the registry; the bootstrap lib, which `modules` and
    # `configs` receive, adds the selection and lacks what they
    # register; the full lib adds the registrations. An ad hoc entry in
    # the selection hands the core lib out, and a config hands out the
    # bootstrap lib.
    lifecycleStagesEachCarryTheirManifest =
      let
        composed = core.mkLib {
          sources = { };
          name = "probe-project";
          libOverlays = lib: {
            base = lib.caisson-core.mkLibOverlay ./fixtures/history-overlays/base;
          };
          libOverlayImports = lib: [
            lib.caisson-core.nixpkgs-lib.overlays.base
            {
              imports = [ ];
              overlay = _final: _prev: { coreSeen = lib; };
            }
          ];
          modules = lib: {
            nixos.local = lib.caisson-core.mkModule "nixos" ({ ... }: { });
          };
          configs = lib: { nixos.probe.bootstrapSeen = lib; };
        };
        coreLib = composed.coreSeen;
        bootstrapLib = composed.caisson-core.configs.nixos.probe.bootstrapSeen;
        coreManifest = coreLib.caisson-core.libManifest;
        bootstrapManifest = bootstrapLib.caisson-core.libManifest;
        fullManifest = composed.caisson-core.libManifest;
        registrationFields = [
          "modules"
          "configs"
          "pkgOverlays"
          "pkgSets"
          "moduleProjects"
        ];
        lacks = manifest: builtins.all (field: !(manifest ? ${field})) registrationFields;
      in
      coreManifest.childless
      && builtins.map (e: e.key) coreManifest.entries == coreNames
      && coreManifest.libOverlays ? base
      && lacks coreManifest
      && !(coreLib ? probe)
      && coreLib.caisson-core ? mkLib
      && bootstrapManifest.childless
      && bootstrapManifest.entries == fullManifest.entries
      && lacks bootstrapManifest
      && bootstrapLib.probe.greeting == "from base"
      && !(bootstrapLib.caisson-core.modules ? nixos)
      && !fullManifest.childless
      && fullManifest.modules.nixos ? local
      && composed.caisson-core.modules.nixos ? local
      && builtins.all (m: m.name == "probe-project" && m.sources == { }) [
        coreManifest
        bootstrapManifest
        fullManifest
      ];

    # A module registered through the lib `modules` receives, the
    # bootstrap lib, closes over the full lib, its author's
    # composition: through `closure-lib` it reaches the registry it was
    # registered into, siblings included.
    lifecycleRegistrationsCloseOverTheFullLib =
      let
        composed = core.mkLib {
          sources = { };
          modules = lib: {
            generic.probe = lib.caisson-core.mkModule "generic" ./fixtures/closure-probe;
            generic.sibling = lib.caisson-core.classes.generic.mkModule ./fixtures/closure-probe;
          };
        };
        closed = module: builtins.head module.imports;
        probe = closed composed.caisson-core.libManifest.modules.generic.probe;
        sibling = closed composed.caisson-core.libManifest.modules.generic.sibling;
      in
      probe.closureModules.generic ? sibling
      && sibling.closureModules.generic ? probe
      && !probe.closureManifest.childless;

    # `pkgSets` is applied to the registered lib, the bootstrap lib with
    # `modules`, `configs` and `pkgOverlays` grafted on, since a package
    # config selects from those registries. Each entry, a function of
    # `{ name, parent }`, is called with the name it is declared under and the
    # registered manifest as its parent, then recorded in the full
    # manifest with a registry event per config in the full stage. The
    # registered manifest is childless and lacks `pkgSets`, so the full
    # manifest lists the configs without containing itself.
    lifecyclePkgSetsAreFinalizedUnderTheRegisteredManifest =
      let
        # A stub integration's constructor: the manifest its function
        # returns records its name and parent, and the lib the
        # constructor was called through.
        stubConfiguration =
          lib:
          { name, parent }:
          {
            _type = "caisson-manifest";
            type = "stub";
            inherit name parent;
            calledThrough = lib.caisson-core.libManifest;
            registryThrough = lib.caisson-core.modules;
          };
        composed = core.mkLib {
          sources = { };
          name = "probe-project";
          modules = lib: {
            generic.local = lib.caisson-core.mkModule "generic" ({ ... }: { });
          };
          pkgOverlays = lib: {
            tool = lib.caisson-core.mkPkgOverlay ({ ... }: { overlay = _final: _prev: { }; });
          };
          pkgSets = lib: {
            default = stubConfiguration lib;
            stable = stubConfiguration lib;
          };
        };
        manifest = composed.caisson-core.libManifest;
        default = manifest.pkgSets.default;
        tail = builtins.genList (i: builtins.elemAt manifest.history (builtins.length manifest.history - 2 + i)) 2;
        identity = e: "${e.operation}:${e.key}:${toString e.index}";
        registeredHistory = builtins.map identity default.parent.history;
      in
      builtins.attrNames manifest.pkgSets == [
        "default"
        "stable"
      ]
      && default.name == "default"
      && manifest.pkgSets.stable.name == "stable"
      && default.parent.childless
      && !(default.parent ? pkgSets)
      && default.parent.entries == manifest.entries
      && default.parent.modules.generic ? local
      && default.parent.pkgOverlays ? tool
      && default.calledThrough.childless
      && default.registryThrough.generic ? local
      && registeredHistory
      == builtins.genList (i: identity (builtins.elemAt manifest.history i)) (
        builtins.length registeredHistory
      )
      && builtins.length manifest.history == builtins.length registeredHistory + 2
      && builtins.map (e: "${e.operation}:${e.key}:${e.origin.project}") tail == [
        "registry:pkgSets.default:probe-project"
        "registry:pkgSets.stable:probe-project"
      ];

    # An entry must be a function whose pattern names exactly `name`
    # and `parent`: an attrset, a function of anything else and a
    # function with a third argument are refused where they are
    # declared, and a function returning something other than a
    # manifest is refused when called.
    lifecyclePkgSetsEntriesMustBeConfigurations =
      let
        pkgSetsOf =
          declared:
          (core.mkLib {
            sources = { };
            pkgSets = _lib: declared;
          }).caisson-core.libManifest.pkgSets;
        manifest = {
          _type = "caisson-manifest";
          type = "stub";
        };
        accepted = pkgSetsOf { default = { name, parent }: manifest // { inherit name; }; };
      in
      accepted.default.name == "default"
      && throws (pkgSetsOf { default = { }; }).default
      && throws (pkgSetsOf { default = _: manifest; }).default
      && throws (pkgSetsOf { default = { name, ... }: manifest; }).default
      && throws (
        pkgSetsOf {
          default =
            {
              name,
              parent,
              extra,
            }:
            manifest;
        }
      ).default
      && throws (pkgSetsOf { default = { name, parent }: { }; }).default;

    # `withManifests` rebuilds a stage from its declaration with phase
    # manifests filled in: the same entries and `libManifest`, a new
    # fixpoint, so an overlay reading `pkgsManifest` through `final`
    # sees it, and `manifestOf` finds it as the last manifest filled in.
    # Further calls keep what is already filled in.
    lifecycleWithManifestsRebuildsTheStage =
      let
        pkgsRecord = {
          _type = "caisson-manifest";
          type = "nixpkgs";
          name = "x86_64-linux";
        };
        evalRecord = {
          _type = "caisson-manifest";
          type = "probe";
        };
        composed = core.mkLib {
          sources = { };
          libOverlays = lib: {
            reader = lib.caisson-core.mkLibOverlay (
              { ... }:
              {
                overlay = final: _prev: { readPkgsManifest = final.caisson-core.pkgsManifest; };
              }
            );
          };
          configs = lib: { generic.probe.bootstrapSeen = lib; };
        };
        bootstrapLib = composed.caisson-core.configs.generic.probe.bootstrapSeen;
        rebuilt = bootstrapLib.caisson-core.withManifests { pkgsManifest = pkgsRecord; };
        twice = rebuilt.caisson-core.withManifests { evalManifest = evalRecord; };
        fullRebuilt = composed.caisson-core.withManifests { pkgsManifest = pkgsRecord; };
      in
      bootstrapLib.caisson-core.pkgsManifest == null
      && bootstrapLib.readPkgsManifest == null
      && rebuilt.caisson-core.pkgsManifest == pkgsRecord
      && rebuilt.readPkgsManifest == pkgsRecord
      && rebuilt.caisson-core.libManifest.childless
      && rebuilt.caisson-core.libManifest.entries == bootstrapLib.caisson-core.libManifest.entries
      && core.manifestOf rebuilt == pkgsRecord
      && twice.caisson-core.pkgsManifest == pkgsRecord
      && twice.caisson-core.evalManifest == evalRecord
      && fullRebuilt.caisson-core.libManifest.pkgSets == { };

    lifecycleWithManifestsFillsInOnlyPhaseManifests =
      let
        composed = core.mkLib { sources = { }; };
        fill = given: (composed.caisson-core.withManifests given).caisson-core;
      in
      throws (fill { libManifest = null; }).libManifest
      && throws (fill { pkgsManifest = { }; }).pkgsManifest
      && throws (fill [ ]).pkgsManifest
      && (fill { pkgsManifest = null; }).pkgsManifest == null;

    # `mkConfiguration` builds a module evaluation's manifest from the
    # `evaluate` of an integration. The stub integration here evaluates
    # a function of the lib, and finalizes the configurations it
    # returns under `children` against the childless manifest, as the
    # children option of an integration does.
    #
    # The top takes the name the composition declares, and its parent
    # is the manifest of the lib. Each view runs on a lib whose
    # `evalManifest` is that view's manifest, and whose `libManifest`
    # and registries are those the composition built.
    lifecycleEvaluationHasAChildlessAndAFullView =
      let
        composed = core.mkLib {
          sources = { };
          name = "probe-project";
          systems = [ "x86_64-linux" ];
          modules = lib: {
            generic.local = lib.caisson-core.mkModule "generic" ({ ... }: { });
          };
        };
        top = composed.caisson-core.finalizeTop (
          stubIntegration "stub" composed (lib: {
            marker = lib.caisson-core.evalManifest.childless;
          })
        );
        seen = top.value.seenLib.caisson-core;
      in
      top._type == "caisson-manifest"
      && top.type == "stub"
      && top.name == "probe-project"
      && !top.childless
      && top.outputs.marker == false
      && top.children == { }
      && top.parent.type == "lib"
      && !top.parent.childless
      && builtins.length top.ancestors == 1
      && top.nearest == { }
      && top.systems == [ "x86_64-linux" ]
      && top.modules.generic ? local
      && top.childlessManifest.childless
      && top.childlessManifest.outputs.marker == true
      && top.childlessManifest.name == "probe-project"
      && !(top.childlessManifest ? childlessManifest)
      && builtins.length top.childlessManifest.inputs == 1
      && builtins.length top.inputs == 2
      && seen.evalManifest.type == "stub"
      && !seen.evalManifest.childless
      && seen.libManifest.name == "probe-project"
      && seen.modules.generic ? local
      && (core.manifestOf top.value.seenLib).type == "stub"
      && composed.caisson-core.evalManifest == null;

    # A child is finalized against the childless view of its parent:
    # its `parent` and its `nearest.<integration>` are that manifest,
    # the chain grows by one manifest per level, and the nearest
    # ancestor of an integration is replaced by a nearer ancestor of
    # the same integration and kept beneath an ancestor of another.
    lifecycleChildrenAreFinalizedAgainstTheChildlessView =
      let
        composed = core.mkLib {
          sources = { };
          name = "probe-project";
        };
        top = composed.caisson-core.finalizeTop (
          stubIntegration "outer" composed (lib: {
            marker = "top:${if lib.caisson-core.evalManifest.childless then "childless" else "full"}";
            children.outer.middle = stubIntegration "outer" lib (lib: {
              marker = "middle";
              children.inner.leaf = stubIntegration "inner" lib (lib: {
                marker = lib.caisson-core.evalManifest.nearest.outer.outputs.marker;
              });
            });
            children.inner.sibling = stubIntegration "inner" lib (_lib: {
              marker = "sibling";
            });
          })
        );
        middle = top.children.outer.middle;
        leaf = middle.children.inner.leaf;
        sibling = top.children.inner.sibling;
      in
      builtins.attrNames top.children == [
        "inner"
        "outer"
      ]
      && top.outputs.marker == "top:full"
      && middle.name == "middle"
      && middle.type == "outer"
      && middle.parent.childless
      && middle.parent.outputs.marker == "top:childless"
      && middle.parent.children == { }
      && middle.nearest.outer.outputs.marker == "top:childless"
      && builtins.length middle.ancestors == 2
      && sibling.name == "sibling"
      && sibling.nearest.outer.childless
      && !(sibling.nearest ? inner)
      && leaf.name == "leaf"
      && leaf.parent.childless
      && leaf.parent.name == "middle"
      && leaf.outputs.marker == "middle"
      && leaf.nearest.outer.name == "middle"
      && builtins.map (ancestor: ancestor.type) leaf.ancestors == [
        "lib"
        "outer"
        "outer"
      ]
      && leaf.value.seenLib.caisson-core.evalManifest.name == "leaf"
      && leaf.value.seenLib.caisson-core.libManifest.name == "probe-project"
      && builtins.length top.inputs == 4
      && builtins.length middle.inputs == 3;

    # The childless evaluation runs only when something reads it. An
    # evaluator that fails in the childless view is harmless to a
    # configuration with no children, and to a configuration whose
    # children read nothing of the value of their parent; a child that
    # reads that value forces it.
    lifecycleChildlessViewIsEvaluatedOnDemand =
      let
        composed = core.mkLib { sources = { }; };
        failing =
          lib: module:
          stubIntegration "stub" lib (
            lib:
            if lib.caisson-core.evalManifest.childless then throw "childless view evaluated" else module lib
          );
        alone = composed.caisson-core.finalizeTop (failing composed (_lib: { marker = "alone"; }));
        parent = composed.caisson-core.finalizeTop (
          failing composed (lib: {
            marker = "parent";
            children.stub.quiet = stubIntegration "stub" lib (_lib: { marker = "quiet"; });
            children.stub.reader = stubIntegration "stub" lib (lib: {
              marker = lib.caisson-core.evalManifest.parent.outputs.marker;
            });
          })
        );
      in
      alone.outputs.marker == "alone"
      && !(alone ? name)
      && parent.outputs.marker == "parent"
      && parent.children.stub.quiet.outputs.marker == "quiet"
      && parent.children.stub.quiet.parent.childless
      && throws parent.children.stub.reader.outputs.marker;

    # An integration that evaluates a configuration at a system
    # declares `perSystem`. A declared configuration is then an
    # evaluation for every system in force where it is declared, and
    # finalizing it gives those evaluations by system: as many as
    # there are systems, also for a single system. Each evaluation
    # carries the name it is declared under and its system, and its
    # parent is the system, which sits beneath the parent that
    # declares the configuration. The systems in force carry on
    # beneath an evaluation.
    lifecyclePerSystemConfigurationIsAnEvaluationPerSystem =
      let
        composedWith =
          systems:
          core.mkLib {
            sources = { };
            name = "probe-project";
            inherit systems;
          };
        evaluationsOn =
          composed:
          composed.caisson-core.finalizeTop (
            perSystemStubIntegration "machine" composed (lib: {
              marker = "at ${lib.caisson-core.evalManifest.system}";
            })
          );
        both = [
          "x86_64-linux"
          "aarch64-linux"
        ];
        several = evaluationsOn (composedWith both);
        single = evaluationsOn (composedWith [ "x86_64-linux" ]);
        x86 = several.x86_64-linux;
      in
      builtins.attrNames several == [
        "aarch64-linux"
        "x86_64-linux"
      ]
      && x86._type == "caisson-manifest"
      && x86.type == "machine"
      && x86.name == "probe-project"
      && x86.system == "x86_64-linux"
      && x86.systems == both
      && x86.parent.type == "system"
      && x86.parent.name == "x86_64-linux"
      && x86.parent.childless
      && x86.parent.children == { }
      && x86.parent.parent.type == "lib"
      && builtins.map (ancestor: ancestor.type) x86.ancestors == [
        "lib"
        "system"
      ]
      && x86.outputs.marker == "at x86_64-linux"
      && several.aarch64-linux.outputs.marker == "at aarch64-linux"
      && x86.value.seenLib.caisson-core.evalManifest.system == "x86_64-linux"
      && x86.childlessManifest.childless
      && x86.childlessManifest.system == "x86_64-linux"
      && builtins.attrNames single == [ "x86_64-linux" ]
      && single.x86_64-linux.outputs.marker == "at x86_64-linux";

    # No system in force is no evaluation: a configuration declared in
    # a composition that declares no systems, or an empty list,
    # finalizes to no evaluations, and nothing is refused.
    lifecyclePerSystemConfigurationWithNoSystemHasNoEvaluation =
      let
        evaluationsOn =
          composed:
          composed.caisson-core.finalizeTop (
            perSystemStubIntegration "machine" composed (_lib: throw "evaluated with no system")
          );
      in
      evaluationsOn (core.mkLib { sources = { }; }) == { }
      &&
        evaluationsOn (
          core.mkLib {
            sources = { };
            systems = [ ];
          }
        ) == { };

    # The parent that declares configurations holds, in its full
    # manifest, each system under `children.system` with the
    # evaluations declared at it, by integration and then name, beside
    # the configurations evaluated once for every system. An
    # evaluation sees the system above it without what is declared
    # under it. A configuration declared beneath an evaluation has a
    # system above it in turn, so a system appears on a path as often
    # as a per-system configuration does.
    lifecycleParentHoldsEvaluationsUnderTheirSystem =
      let
        composed = core.mkLib {
          sources = { };
          name = "probe-project";
          systems = [
            "x86_64-linux"
            "aarch64-linux"
          ];
        };
        machine =
          lib: marker: children:
          perSystemStubIntegration "machine" lib (lib: {
            marker = "${marker} at ${lib.caisson-core.evalManifest.system}";
            children = children lib;
          });
        top = composed.caisson-core.finalizeTop (
          stubIntegration "holder" composed (lib: {
            marker = "holder";
            children.machine.alpha = machine lib "alpha" (lib: {
              machine.image = machine lib "image on ${lib.caisson-core.evalManifest.system}" (_lib: { });
            });
            children.machine.beta = machine lib "beta" (_lib: { });
            children.stub.plain = stubIntegration "stub" lib (_lib: {
              marker = "plain";
            });
          })
        );
        x86 = top.children.system.x86_64-linux;
        alpha = x86.children.machine.alpha;
        image = alpha.children.system.aarch64-linux.children.machine.image;
      in
      builtins.attrNames top.children == [
        "stub"
        "system"
      ]
      && builtins.attrNames top.children.system == [
        "aarch64-linux"
        "x86_64-linux"
      ]
      && top.children.stub.plain.outputs.marker == "plain"
      && x86.type == "system"
      && x86.name == "x86_64-linux"
      && !x86.childless
      && x86.parent.childless
      && x86.parent.type == "holder"
      && builtins.attrNames x86.children == [ "machine" ]
      && builtins.attrNames x86.children.machine == [
        "alpha"
        "beta"
      ]
      && alpha.name == "alpha"
      && alpha.outputs.marker == "alpha at x86_64-linux"
      && alpha.parent.type == "system"
      && alpha.parent.children == { }
      && alpha.nearest.holder.childless
      && x86.children.machine.beta.outputs.marker == "beta at x86_64-linux"
      && builtins.attrNames alpha.children.system == [
        "aarch64-linux"
        "x86_64-linux"
      ]
      && image.outputs.marker == "image on x86_64-linux at aarch64-linux"
      && image.nearest.machine.system == "x86_64-linux"
      && builtins.map (ancestor: "${ancestor.type}:${ancestor.name}") image.ancestors == [
        "lib:probe-project"
        "holder:probe-project"
        "system:x86_64-linux"
        "machine:alpha"
        "system:aarch64-linux"
      ];

    # The selection of a package set that a configuration records is
    # in force beneath it, through levels that record none and through
    # a system, until a configuration beneath records another. It is
    # absent above and beside the configuration that records it.
    lifecycleARecordedPkgSetSelectionIsInForceBeneath =
      let
        composed = core.mkLib {
          sources = { };
          name = "probe-project";
          systems = [ "x86_64-linux" ];
        };
        selecting =
          selection: lib: module:
          lib.caisson-core.mkConfiguration {
            type = "stub";
            record = if selection == null then { } else { pkgSet = selection; };
            evaluate = stubEvaluate module;
          };
        top = composed.caisson-core.finalizeTop (
          selecting null composed (lib: {
            children.stub.assigned = selecting "stable" lib (lib: {
              children.stub.between = selecting null lib (lib: {
                children.stub.deep = selecting null lib (_lib: { });
                children.stub.other = selecting "edge" lib (lib: {
                  children.stub.below = selecting null lib (_lib: { });
                });
              });
              children.machine.host = perSystemStubIntegration "machine" lib (_lib: { });
            });
            children.stub.beside = selecting null lib (_lib: { });
          })
        );
        assigned = top.children.stub.assigned;
        between = assigned.children.stub.between;
        selectionOf = manifest: manifest.pkgSet or null;
      in
      selectionOf top == null
      && selectionOf top.children.stub.beside == null
      && selectionOf assigned == "stable"
      && selectionOf between == "stable"
      && selectionOf between.children.stub.deep == "stable"
      && selectionOf assigned.children.system.x86_64-linux.children.machine.host == "stable"
      && selectionOf between.children.stub.other == "edge"
      && selectionOf between.children.stub.other.children.stub.below == "edge";

    # What an evaluation registers for the configurations beneath it
    # joins the module registry they see and the default selection of
    # the class, at any depth and through a system. It reaches nothing
    # at the evaluation itself or beside it, and a level beneath
    # replaces an entry for what is beneath that level.
    lifecycleRegistrationsReachWhatIsBeneath =
      let
        composed = core.mkLib {
          sources = { };
          name = "probe-project";
          systems = [ "x86_64-linux" ];
        };
        seen = manifest: manifest.value.seenLib.caisson-core.modules.stub or { };
        selected =
          manifest:
          builtins.concatMap (selection: selection manifest.value.seenLib) (
            manifest.defaultModuleImports.stub or [ ]
          );
        top = composed.caisson-core.finalizeTop (
          stubIntegration "holder" composed (lib: {
            forChildren.modules.stub.gift = "from the holder";
            forChildren.modules.stub.other = "also from the holder";
            forChildren.defaultModuleImports.stub = [ (lib: [ lib.caisson-core.modules.stub.gift ]) ];
            children.stub.inner = stubIntegration "stub" lib (lib: {
              forChildren.modules.stub.gift = "from inner";
              forChildren.defaultModuleImports.stub = [ (lib: [ lib.caisson-core.modules.stub.other ]) ];
              children.stub.deep = stubIntegration "stub" lib (_lib: { });
            });
            children.machine.host = perSystemStubIntegration "machine" lib (_lib: { });
          })
        );
        beside = composed.caisson-core.finalizeTop (stubIntegration "stub" composed (_lib: { }));
        inner = top.children.stub.inner;
        deep = inner.children.stub.deep;
        host = top.children.system.x86_64-linux.children.machine.host;
      in
      seen top == { }
      && seen beside == { }
      && top.forChildren.modules.stub.gift == "from the holder"
      && seen inner == {
        gift = "from the holder";
        other = "also from the holder";
      }
      && inner.modules.stub == seen inner
      && selected inner == [ "from the holder" ]
      && seen host == seen inner
      && selected host == [ "from the holder" ]
      && seen deep == {
        gift = "from inner";
        other = "also from the holder";
      }
      && selected deep == [
        "from inner"
        "also from the holder"
      ];

    # `elide` keeps, of each path, its last segment and the segments
    # where paths that end in the same name fork. A name that is alone
    # stays bare whatever sits above it, so a system above a
    # configuration with a single system in force drops out, and the
    # same name at several systems keeps the system.
    elideKeepsTheNameAndTheForks =
      let
        segment = type: name: { inherit type name; };
        system = segment "system";
        nixos = segment "nixos";
        home = segment "home-manager";
        structural = segment "structural";
      in
      core.elide [ ] == [ ]
      && core.elide [
        [
          (system "x86_64-linux")
          (nixos "hostname1")
        ]
        [
          (system "x86_64-linux")
          (nixos "hostname2")
        ]
        [
          (system "aarch64-linux")
          (nixos "hostname2")
        ]
      ] == [
        [ "hostname1" ]
        [
          "x86_64-linux"
          "hostname2"
        ]
        [
          "aarch64-linux"
          "hostname2"
        ]
      ]
      # A shared prefix and a segment on which no paths diverge never
      # appear.
      && core.elide [
        [
          (nixos "hostname2")
          (system "x86_64-linux")
          (structural "sub")
          (home "user")
        ]
        [
          (nixos "hostname2")
          (system "aarch64-linux")
          (structural "sub")
          (home "user")
        ]
      ] == [
        [
          "x86_64-linux"
          "user"
        ]
        [
          "aarch64-linux"
          "user"
        ]
      ]
      # Names that do not collide gain nothing, though their paths
      # differ.
      && core.elide [
        [
          (structural "top")
          (structural "a")
          (nixos "laptop")
        ]
        [
          (structural "top")
          (structural "b")
          (nixos "desktop")
        ]
      ] == [
        [ "laptop" ]
        [ "desktop" ]
      ]
      # A fork between branches that hold a name under several types
      # keeps the type.
      && core.elide [
        [
          (nixos "nas")
          (home "chris")
        ]
        [
          (segment "colmena" "nas")
          (home "chris")
        ]
      ] == [
        [
          "nixos/nas"
          "chris"
        ]
        [
          "colmena/nas"
          "chris"
        ]
      ]
      # A fork inside a branch is kept beside the fork above it.
      && core.elide [
        [
          (system "x86_64-linux")
          (nixos "hostname1")
          (home "user")
        ]
        [
          (system "x86_64-linux")
          (nixos "hostname2")
          (home "user")
        ]
        [
          (system "aarch64-linux")
          (nixos "hostname2")
          (home "user")
        ]
      ] == [
        [
          "x86_64-linux"
          "hostname1"
          "user"
        ]
        [
          "x86_64-linux"
          "hostname2"
          "user"
        ]
        [
          "aarch64-linux"
          "user"
        ]
      ]
      # Where several segments would tell paths apart, the fork is the
      # segment nearest the top: the widest scope that separates them.
      # The segments beneath it differ too and are left out.
      && core.elide [
        [
          (structural "a")
          (structural "x")
          (nixos "host-1")
        ]
        [
          (structural "b")
          (structural "y")
          (nixos "host-1")
        ]
        [
          (structural "a")
          (structural "x")
          (nixos "host-2")
        ]
      ] == [
        [
          "a"
          "host-1"
        ]
        [
          "b"
          "host-1"
        ]
        [ "host-2" ]
      ]
      # The same holds where the segments beneath the fork are
      # systems: a name in two groups, each at another system, is told
      # apart by the group, and the system is left out.
      && core.elide [
        [
          (structural "a")
          (system "x86_64-linux")
          (nixos "host-1")
        ]
        [
          (structural "b")
          (system "aarch64-linux")
          (nixos "host-1")
        ]
      ] == [
        [
          "a"
          "host-1"
        ]
        [
          "b"
          "host-1"
        ]
      ]
      # Equal paths stay equal, for whoever publishes them to report.
      && core.elide [
        [ (nixos "twin") ]
        [ (nixos "twin") ]
      ] == [
        [ "twin" ]
        [ "twin" ]
      ];

    # What `mkConfiguration` returns is a configuration, a function of
    # exactly `{ name, parent }`, so a parent finalizes it as it
    # finalizes any other. The `record` of an integration is carried on
    # both views and may not name a field mkConfiguration writes. A top is
    # finalized only under a lib that carries a manifest.
    lifecycleEvaluationIsAConfiguration =
      let
        composed = core.mkLib {
          sources = { };
          name = "probe-project";
        };
        configuration =
          record:
          composed.caisson-core.mkConfiguration {
            type = "stub";
            evaluate = _: { value = { }; };
            inherit record;
          };
        recorded = composed.caisson-core.finalizeTop (configuration {
          ecosystemSrc = "/src";
        });
        child = composed.caisson-core.finalizeChild {
          name = "declared";
          parent = recorded.childlessManifest;
        } (configuration { });
      in
      builtins.functionArgs (configuration { }) == {
        name = false;
        parent = false;
      }
      && recorded.ecosystemSrc == "/src"
      && recorded.childlessManifest.ecosystemSrc == "/src"
      && recorded.outputs == { }
      && child.name == "declared"
      && child.nearest.stub.name == "probe-project"
      && throws (composed.caisson-core.finalizeTop (configuration { children = { }; }))._type
      && throws (composed.caisson-core.finalizeTop { })
      && throws (core.finalizeTop (configuration { }));

    lifecyclePkgSetsMustBeAFunctionReturningAnAttrset =
      throws (
        core.mkLib {
          sources = { };
          pkgSets = { };
        }
      )
      && throws (
        core.mkLib {
          sources = { };
          pkgSets = _lib: [ ];
        }
      );

    # The history of each stage begins with the history of the stage
    # before it: the prefix consistency the record promises, compared
    # on each event's identity.
    lifecycleStageHistoriesArePrefixes =
      let
        composed = core.mkLib {
          sources = { };
          name = "probe-project";
          libOverlays = lib: {
            base = lib.caisson-core.mkLibOverlay ./fixtures/history-overlays/base;
            top = lib.caisson-core.mkLibOverlay ./fixtures/history-overlays/top;
          };
          libOverlayImports = lib: [
            lib.caisson-core.nixpkgs-lib.overlays.base
            lib.caisson-core.nixpkgs-lib.overlays.top
            {
              imports = [ ];
              overlay = _final: _prev: { coreSeen = lib; };
            }
          ];
          modules = lib: {
            nixos.local = lib.caisson-core.mkModule "nixos" ({ ... }: { });
          };
          configs = lib: { nixos.probe.bootstrapSeen = lib; };
        };
        identity = e: {
          inherit (e)
            manifest
            type
            operation
            key
            index
            origin
            ;
        };
        historyOf = lib: builtins.map identity lib.caisson-core.libManifest.history;
        core' = historyOf composed.coreSeen;
        bootstrap = historyOf composed.caisson-core.configs.nixos.probe.bootstrapSeen;
        full = historyOf composed;
        prefix = short: long: short == builtins.genList (builtins.elemAt long) (builtins.length short);
      in
      prefix core' bootstrap
      && prefix bootstrap full
      && builtins.length core' < builtins.length bootstrap
      && builtins.length bootstrap < builtins.length full
      && builtins.all (e: e.operation == "registry") (
        builtins.genList (i: builtins.elemAt full (builtins.length bootstrap + i)) (
          builtins.length full - builtins.length bootstrap
        )
      );

    # A registration under a forced entry's key replaces it from the
    # bootstrap stage on: the core lib keeps the entry caisson-core ships,
    # the returned lib has the replacement, and the history records the
    # replacement as a later layer, so `definers` names it the winner.
    lifecycleReplacingAForcedEntryAppliesFromBootstrap =
      let
        composed = core.mkLib {
          sources = { };
          libOverlays = lib: {
            "caisson-core/pins" = lib.caisson-core.mkLibOverlay (
              { ... }:
              {
                overlay = _final: prev: {
                  caisson-core = prev.caisson-core // {
                    pins = "replaced";
                  };
                };
              }
            );
          };
          libOverlayImports = lib: [
            {
              imports = [ ];
              overlay = _final: _prev: { coreSeen = lib; };
            }
          ];
        };
        pinsDefiners = core.definers composed.caisson-core.libManifest [
          "caisson-core"
          "pins"
        ];
      in
      composed.caisson-core.pins == "replaced"
      && builtins.isAttrs composed.coreSeen.caisson-core.pins
      && builtins.map (d: d.key) pinsDefiners == [
        "caisson-core/pins"
        "caisson-core/pins"
      ]
      && (builtins.elemAt pinsDefiners 1).value == "replaced";

    # A registry function takes its reader from the library it is
    # handed, so a composition that registers another
    # `caisson-core/readers` entry reads its directories with that
    # entry.
    lifecycleReadersComeFromTheLibraryHandedIn =
      let
        composed = core.mkLib {
          sources = { };
          libOverlays = lib: {
            "caisson-core/readers" = lib.caisson-core.mkLibOverlay (
              { ... }:
              {
                overlay = _final: prev: {
                  caisson-core = prev.caisson-core // {
                    mkModules = dir: { generic.readBy = "the replacement, at ${baseNameOf dir}"; };
                  };
                };
              }
            );
          };
          modules = lib: lib.caisson-core.mkModules ./fixtures/modules-dir;
        };
      in
      composed.caisson-core.modules.generic == {
        readBy = "the replacement, at modules-dir";
      };

    # `libOverlayImports` replaces the default selection, every
    # registered overlay, and `extraLibOverlayImports` adds to the
    # selection, whichever it is.
    lifecycleExtraLibOverlayImportsAddToTheSelection =
      let
        marking = name: {
          imports = [ ];
          overlay = _final: _prev: { ${name} = true; };
        };
        compose =
          selection:
          core.mkLib (
            {
              sources = { };
              libOverlays = _lib: {
                one = marking "one";
                two = marking "two";
              };
            }
            // selection
          );
        marks = lib: {
          one = lib.one or false;
          two = lib.two or false;
          added = lib.added or false;
        };
      in
      marks (compose { }) == {
        one = true;
        two = true;
        added = false;
      }
      && marks (compose {
        libOverlayImports = lib: [ lib.caisson-core.nixpkgs-lib.overlays.one ];
      }) == {
        one = true;
        two = false;
        added = false;
      }
      && marks (compose {
        extraLibOverlayImports = _lib: [ (marking "added") ];
      }) == {
        one = true;
        two = true;
        added = true;
      }
      && marks (compose {
        libOverlayImports = lib: [ lib.caisson-core.nixpkgs-lib.overlays.one ];
        extraLibOverlayImports = _lib: [ (marking "added") ];
      }) == {
        one = true;
        two = false;
        added = true;
      }
      && throws (compose {
        extraLibOverlayImports = [ ];
      });

    # `definers` names every layer that defines a path, the winner last,
    # with the value after each layer and its binding position when the
    # position lies in the layer's file. A layer returning
    # `prev.x // { ... }` carries the names under `x` without defining
    # them, and a computed name reports no position.
    lifecycleDefinersNameTheWinnerAndTheShadowed =
      let
        composed = core.mkLib {
          sources = { };
          libOverlays = lib: {
            base = lib.caisson-core.mkLibOverlay ./fixtures/history-overlays/base;
            top = lib.caisson-core.mkLibOverlay ./fixtures/history-overlays/top;
          };
          libOverlayImports = lib: [
            lib.caisson-core.nixpkgs-lib.overlays.base
            lib.caisson-core.nixpkgs-lib.overlays.top
          ];
        };
        manifest = composed.caisson-core.libManifest;
        definersOf = path: core.definers manifest path;
        greeting = definersOf [
          "probe"
          "greeting"
        ];
        made = definersOf [
          "probe"
          "made"
        ];
        computed = definersOf [
          "probe"
          "computed"
        ];
      in
      builtins.map (d: d.key) greeting == [
        "base"
        "top"
      ]
      && builtins.map (d: d.value) greeting == [
        "from base"
        "from top"
      ]
      && composed.probe.greeting == "from top"
      && builtins.all (
        d: d.position.file == toString ./fixtures/history-overlays + "/${d.key}/default.nix"
      ) greeting
      && builtins.map (d: d.key) made == [ "base" ]
      && (builtins.head made).position.line == 8
      && builtins.map (d: d.key) computed == [ "base" ]
      && (builtins.head computed).position == null
      && definersOf [ "absent" ] == [ ];

    lifecycleNameMustBeAString =
      throws (
        core.mkLib {
          sources = { };
          name = [ "my-project" ];
        }
      )
      && throws (
        core.mkLib {
          sources = { };
          name = 1;
        }
      );

    lifecycleEcosystemDeclarationsJoinTheManifest =
      let
        composed = core.mkLib {
          sources = { };
          defaultEcosystemSrc = {
            nixpkgs = "/probe-nixpkgs";
          };
        };
      in
      composed.caisson-core.libManifest.defaultEcosystemSrc.nixpkgs == "/probe-nixpkgs";

    lifecycleDefaultEcosystemSrcMustBeAnAttrset = throws (
      core.mkLib {
        sources = { };
        defaultEcosystemSrc = 42;
      }
    );

    lifecycleInjectedMkLibIsTheSameMkLib =
      let
        outer = core.mkLib { sources = { }; };
        inner = outer.caisson-core.mkLib {
          sources = { };
          defaultEcosystemSrc.nixpkgs-lib = ./fixtures/nixpkgs-lib-stub;
          libOverlays = lib: {
            probe = lib.caisson-core.mkLibOverlay (
              { entries, ... }:
              {
                imports = [ entries.nixpkgs-lib ];
                overlay = _final: _prev: { };
              }
            );
          };
        };
      in
      inner.stubIncrement 1 == 2;

    lifecycleImportApplyThreadsStaticArgs =
      let
        applied = core.importApply ({ n }: { config.value = n; }) { n = 7; };
      in
      applied.config.value == 7;

    lifecycleProjectsRegisterAsUnits =
      let
        dep = {
          libOverlays.greeter = {
            imports = [ ];
            overlay = _final: _prev: {
              greet = name: "hello, ${name}";
            };
          };
          modules.nixos.service = {
            config.origin = "dep";
          };
        };
        composed = core.mkLib {
          sources = { };
          projects = {
            inherit dep;
          };
        };
      in
      composed.greet "world" == "hello, world"
      && composed.caisson-core.modules.nixos."dep/service".config.origin == "dep"
      && builtins.attrNames composed.caisson-core.libManifest.projects == [ "dep" ]
      # The manifest dictionaries carry the registered union, so the
      # export side sees project entries like hand-registered entries.
      &&
        builtins.attrNames composed.caisson-core.libManifest.libOverlays == coreNames
        ++ [
          "dep/greeter"
          "nixpkgs-lib"
        ]
      && composed.caisson-core.libManifest.modules.nixos."dep/service".config.origin == "dep";

    lifecycleProjectOverlaysObeySelection =
      let
        dep = {
          libOverlays.marker = {
            imports = [ ];
            overlay = _final: _prev: {
              fromDep = true;
            };
          };
        };
        composed = core.mkLib {
          sources = { };
          projects = {
            inherit dep;
          };
          libOverlays = lib: {
            local = lib.caisson-core.mkLibOverlay ({ ... }: { overlay = _final: _prev: { fromLocal = true; }; });
          };
          # Per-item choice over the combined dictionary: prefixed
          # project names beside local short names.
          libOverlayImports = lib: [ lib.caisson-core.nixpkgs-lib.overlays.local ];
        };
      in
      composed.fromLocal
      && !(composed ? fromDep)
      # Selection controls application only; the unselected project
      # overlay stays registered in the manifest dictionary.
      &&
        builtins.attrNames composed.caisson-core.libManifest.libOverlays == coreNames
        ++ [
          "dep/marker"
          "local"
          "nixpkgs-lib"
        ];

    lifecycleLocalModulesBeatProjectModules =
      let
        dep = {
          modules.nixos.service = {
            config.origin = "project";
          };
        };
        composed = core.mkLib {
          sources = { };
          projects = {
            inherit dep;
          };
          modules = composedLib: {
            nixos."dep/service" = composedLib.caisson-core.mkModule "nixos" (
              { ... }: { config.origin = "local"; }
            );
          };
        };
      in
      composed.caisson-core.modules.nixos."dep/service".config.origin == "local"
      && composed.caisson-core.libManifest.modules.nixos."dep/service".config.origin == "local";

    # Every registered lib overlay records where it came from: null for a
    # local registration, the project's name for a contributed entry, and
    # `caisson-core` for the entries caisson-core publishes itself. The
    # filter on `project == null` is the local view an export selector
    # keeps.
    lifecycleLibOverlaysRecordTheirProject =
      let
        dep = {
          libOverlays.greeter = {
            imports = [ ];
            overlay = _final: _prev: { };
          };
        };
        registry =
          (core.mkLib {
            sources = { };
            projects = {
              inherit dep;
            };
            libOverlays = lib: {
              local = lib.caisson-core.mkLibOverlay ({ ... }: { overlay = _final: _prev: { }; });
            };
          }).caisson-core.libManifest.libOverlays;
      in
      registry."dep/greeter".project == "dep"
      && registry.local.project == null
      && registry.nixpkgs-lib.project == "caisson-core"
      && registry."caisson-core/compose".project == "caisson-core"
      && builtins.filter (name: registry.${name}.project == null) (builtins.attrNames registry) == [
        "local"
      ];

    # Beside the module dictionary, the project each module came from; a
    # local registration that shadows a project's entry is local.
    lifecycleModuleProjectsRecordOrigins =
      let
        dep = {
          modules.nixos = {
            service = {
              config.origin = "dep";
            };
            shadowed = {
              config.origin = "dep";
            };
          };
        };
        manifest =
          (core.mkLib {
            sources = { };
            projects = {
              inherit dep;
            };
            modules = composedLib: {
              nixos = {
                here = composedLib.caisson-core.mkModule "nixos" ({ ... }: { });
                "dep/shadowed" = composedLib.caisson-core.mkModule "nixos" ({ ... }: { });
              };
            };
          }).caisson-core.libManifest;
      in
      manifest.moduleProjects.nixos == {
        "dep/service" = "dep";
        "dep/shadowed" = null;
        here = null;
      }
      && builtins.attrNames manifest.moduleProjects.nixos == builtins.attrNames manifest.modules.nixos;

    lifecycleProjectsMustBeAnAttrset = throws (
      core.mkLib {
        sources = { };
        projects = 42;
      }
    );

    # caisson-core composes itself: the entries that make the
    # top-level value are those mkLib composes into a consumer, so
    # a composition assembled with `compose` directly takes them as
    # keyed entries.
    lifecycleCoreEntriesComposeDirectly =
      let
        r = compose { entries = builtins.attrValues (core.coreEntries { sources = { }; }); };
      in
      builtins.isFunction r.lib.caisson-core.mkLibOverlay
      && builtins.isFunction r.lib.caisson-core.mkLib
      && r.lib.caisson-core.modules == { }
      && r.meta.order == coreNames
      && builtins.attrNames r.lib.caisson-core == builtins.attrNames core;

    # The record states a directory reader's pin files relative to the
    # root when the directory lies in the root's tree, and keeps
    # `pin.dir` otherwise; the source tree itself is what the closure
    # sees, unchanged.
    lifecycleRecordRelativizesPinFiles =
      let
        read = core.pins.flake-compat ./fixtures/pins-flake-compat;
        inside = core.mkLib {
          inherit (read) sources;
          root = {
            outPath = ./fixtures;
            dirty = false;
          };
          libOverlays = lib: {
            probe = lib.caisson-core.mkLibOverlay (
              { closure-inputs, ... }:
              {
                overlay = _final: _prev: { closed = closure-inputs; };
              }
            );
          };
        };
        outside = core.mkLib {
          inherit (read) sources;
          root = {
            outPath = ./fixtures/pins-flake;
            dirty = false;
          };
        };
        noRoot = core.mkLib { inherit (read) sources; };
        pinOf = lib: lib.caisson-core.libManifest.sources.local.pin;
      in
      (pinOf inside).files == {
        refs = "pins-flake-compat/flake.nix";
        revisions = "pins-flake-compat/flake.lock";
      }
      && !((pinOf inside) ? dir)
      && inside.closed.local.pin.dir == ./fixtures/pins-flake-compat
      && (pinOf outside).dir == ./fixtures/pins-flake-compat
      && (pinOf outside).files.refs == "flake.nix"
      && (pinOf noRoot).dir == ./fixtures/pins-flake-compat;

    # At a flake top the root's out path is `self.outPath`, which the
    # flake's outputs cannot read while they are being computed; the
    # record reads it only for a directory reader's source, so resolving
    # a flake input from the manifest leaves it unread.
    lifecycleRecordLeavesTheRootUnread =
      (core.mkLib {
        sources.probe = {
          outPath = ./fixtures/pins-plain-dir;
          pin.system = "flake";
        };
        root = {
          outPath = throw "root read";
          dirty = false;
        };
      }).caisson-core.libManifest.sources.probe.outPath == ./fixtures/pins-plain-dir;

    # Resolution reads the pinned sources: a source named exactly as
    # the ecosystem supplies it when nothing is declared.
    lifecycleNixpkgsLibFromSources =
      (core.mkLib {
        sources.nixpkgs-lib = ./fixtures/nixpkgs-lib-stub;
        libOverlays = lib: {
          a = lib.caisson-core.mkLibOverlay (
            { entries, ... }:
            {
              imports = [ entries.nixpkgs-lib ];
              overlay = _final: _prev: { };
            }
          );
        };
      }).stubIncrement 1 == 2;

    # The pin readers. The suite fetches nothing: `pins.flake` reads a
    # fake inputs attrset and the fixture's lock; `pins.flake-compat` is
    # exercised on a relative path input, which is located, not fetched,
    # and its remote inputs through the lock descriptors; `pins.npins`
    # through its descriptors and the `pin` record of tarball pins,
    # whose fetch is not forced by reading the record.
    pinsFlakeSourcesAndRoot =
      let
        read = core.pins.flake pinsFlakeInputs;
        s = read.sources;
      in
      builtins.attrNames s == [
        "follower"
        "nixpkgs"
        "nonflake"
        "overridden"
        "unlocked"
      ]
      && read.root == {
        outPath = ./fixtures/pins-flake;
        dirty = false;
        rev = "0000000000000000000000000000000000000abc";
        shortRev = "0000000";
        dirtyRev = null;
        dirtyShortRev = null;
        lastModified = 1;
        lastModifiedDate = "19700101000001";
        narHash = "sha256-SELF";
      }
      # The source is the input itself, outputs included, plus `pin`.
      && s.nixpkgs.lib == "nixpkgs-lib-marker"
      && s.nixpkgs.pin == {
        system = "flake";
        files = {
          refs = "flake.nix";
          revisions = "flake.lock";
        };
        overridden = false;
        url = "github:NixOS/nixpkgs/nixos-unstable";
        follows = null;
        rev = "1111111111111111111111111111111111111111";
        narHash = "sha256-NIXPKGS";
        lastModified = 10;
      };

    pinsFlakeFollowsNonFlakeAndOverride =
      let
        s = (core.pins.flake pinsFlakeInputs).sources;
      in
      # A follows is the tree it lands on, with the path it follows.
      s.follower.pin.follows == [ "nixpkgs" ]
      && s.follower.pin.url == "github:NixOS/nixpkgs/nixos-unstable"
      && s.follower.pin.rev == s.nixpkgs.pin.rev
      && s.nixpkgs.pin.follows == null
      && s.nonflake.pin.url == "git+https://example.com/nonflake.git?ref=main"
      && !s.nonflake.pin.overridden
      # The resolved tree differs from the lock: an override was in force.
      && s.overridden.pin.overridden
      && s.overridden.pin.narHash == "sha256-OVERRIDE"
      # An input the lock does not name carries no ref.
      && s.unlocked.pin.url == null
      && !s.unlocked.pin.overridden;

    # Inside a flake's `outputs`, `self` cannot be read while the
    # outputs are being computed, and the lock is read from `self`. A
    # source's `pin` has names known without reading the lock, so
    # asking what a pin holds leaves `self` unread.
    pinsFlakePinNamesDoNotReadTheLock =
      builtins.attrNames
        (core.pins.flake {
          self = throw "self forced";
          nixpkgs = pinsFlakeInputs.nixpkgs;
        }).sources.nixpkgs.pin == [
        "files"
        "follows"
        "lastModified"
        "narHash"
        "overridden"
        "rev"
        "system"
        "url"
      ];

    # A bare path or string input is a tree with that out path.
    pinsFlakeBareInput =
      let
        s =
          (core.pins.flake {
            self.outPath = ./fixtures/pins-plain-dir;
            bare = "/nix/store/44444444444444444444444444444444-source";
          }).sources;
      in
      s.bare.outPath == "/nix/store/44444444444444444444444444444444-source"
      && s.bare.pin.system == "flake"
      && !s.bare.pin.overridden;

    pinsFlakeDirtyRoot =
      (core.pins.flake {
        self = {
          outPath = ./fixtures/pins-flake;
          dirtyRev = "0000000000000000000000000000000000000abc-dirty";
          lastModified = 2;
        };
      }).root == {
        outPath = ./fixtures/pins-flake;
        dirty = true;
        rev = null;
        shortRev = null;
        dirtyRev = "0000000000000000000000000000000000000abc-dirty";
        dirtyShortRev = null;
        lastModified = 2;
        lastModifiedDate = null;
        narHash = null;
      };

    # Inside a flake's `outputs`, asking which attributes `self` has
    # forces the outputs being computed. The root's names are fixed, so
    # a root read from a `self` that must not be forced is still a set
    # whose names can be read.
    pinsFlakeRootNamesDoNotForceSelf =
      builtins.attrNames (core.pins.flake { self = throw "self forced"; }).root == [
        "dirty"
        "dirtyRev"
        "dirtyShortRev"
        "lastModified"
        "lastModifiedDate"
        "narHash"
        "outPath"
        "rev"
        "shortRev"
      ];

    pinsFlakeRefusesMissingSelfAndOldLock =
      throws (core.pins.flake { nixpkgs = { }; }).root
      && throws
        (core.pins.flake {
          self.outPath = ./fixtures/pins-flake-v4;
          x.narHash = "sha256-X";
        }).sources.x.pin;

    pinsFlakeCompatRelativeInput =
      let
        s = (core.pins.flake-compat ./fixtures/pins-flake-compat).sources;
      in
      builtins.attrNames s == [
        "alias"
        "local"
        "localFlake"
        "nested"
        "remote"
      ]
      && s.local.outPath == ./fixtures/pins-flake-compat/sub
      && builtins.pathExists (s.local.outPath + "/marker")
      && s.local.pin == {
        system = "flake";
        files = {
          refs = "flake.nix";
          revisions = "flake.lock";
        };
        dir = ./fixtures/pins-flake-compat;
        url = "path:./sub";
        follows = null;
      }
      && s.alias.outPath == s.local.outPath
      && s.alias.pin.follows == [ "local" ];

    # A flake input comes with its outputs, as Nix hands it over, so a
    # partition's `extraInputs` can read `inputs.<name>.flakeModule`.
    pinsFlakeCompatFlakeInputCarriesOutputs =
      let
        s = (core.pins.flake-compat ./fixtures/pins-flake-compat).sources;
      in
      s.localFlake.flakeModule == "the-module"
      && s.localFlake._type == "flake"
      && s.localFlake.outputs.flakeModule == "the-module"
      && s.localFlake.outPath == ./fixtures/pins-flake-compat/subflake
      && s.localFlake.pin.url == "path:./subflake"
      && !(s.local ? outputs);

    pinsFlakeCompatRefusals =
      let
        s = (core.pins.flake-compat ./fixtures/pins-flake-compat).sources;
      in
      throws s.nested.outPath
      && throws (core.pins.flake-compat ./fixtures/pins-plain-dir).sources
      && throws (core.pins.flake-compat ./fixtures/pins-flake-v4).sources;

    pinsFlakeLockDescriptors =
      let
        d = flakeLock.descriptors (flakeLock.readLock ./fixtures/pins-flake-compat);
      in
      d.remote == {
        node = "remote";
        locked = {
          dir = "pkg";
          lastModified = 40;
          narHash = "sha256-REMOTE";
          owner = "example";
          repo = "remote";
          rev = "4444444444444444444444444444444444444444";
          type = "github";
        };
        original = {
          dir = "pkg";
          owner = "example";
          ref = "v1";
          repo = "remote";
          type = "github";
        };
        flake = true;
        relative = false;
        parent = [ ];
      }
      && d.nested.node == "inner"
      && d.nested.follows == [
        "remote"
        "inner"
      ]
      && d.nested.relative
      && d.nested.parent == [ "remote" ]
      && flakeLock.refToString d.remote.original == "github:example/remote/v1?dir=pkg";

    # The fallback renderer, used where the evaluator has no
    # flakeRefToString, renders as the evaluator does.
    pinsFlakeRefFallbackRenders =
      builtins.map flakeLock.renderRef [
        {
          type = "github";
          owner = "NixOS";
          repo = "nixpkgs";
        }
        {
          type = "github";
          owner = "NixOS";
          repo = "nixpkgs";
          ref = "nixos-unstable";
        }
        {
          type = "github";
          owner = "a";
          repo = "b";
          ref = "main";
          dir = "sub";
        }
        {
          type = "github";
          owner = "a";
          repo = "b";
          host = "git.example.com";
        }
        {
          type = "git";
          url = "https://example.com/x.git";
          ref = "main";
          submodules = true;
        }
        {
          type = "path";
          path = "./sub";
        }
        {
          type = "indirect";
          id = "nixpkgs";
          ref = "nixos-24.05";
        }
        {
          type = "tarball";
          url = "https://example.com/x.tar.gz";
        }
      ] == [
        "github:NixOS/nixpkgs"
        "github:NixOS/nixpkgs/nixos-unstable"
        "github:a/b/main?dir=sub"
        "github:a/b?host=git.example.com"
        "git+https://example.com/x.git?ref=main&submodules=1"
        "path:./sub"
        "flake:nixpkgs/nixos-24.05"
        "https://example.com/x.tar.gz"
      ];

    pinsNpinsDescriptors =
      let
        d = npinsData.describe "test" (builtins.fromJSON (builtins.readFile ./fixtures/pins-npins/sources.json));
      in
      d.github == {
        type = "Git";
        hash = "sha256-GITHUB";
        url = "https://github.com/nixos/nixpkgs.git";
        rev = "5555555555555555555555555555555555555555";
        narHash = "sha256-GITHUB";
        fetch.tarball = {
          url = "https://github.com/nixos/nixpkgs/archive/5555555555555555555555555555555555555555.tar.gz";
          sha256 = "sha256-GITHUB";
        };
      }
      # Submodules take the git fetch, as npins does.
      && d.plain-git.fetch.git == {
        url = "https://example.com/plain.git";
        submodules = true;
        rev = "6666666666666666666666666666666666666666";
        narHash = "sha256-PLAIN";
        name = "source";
      }
      && d.channel.narHash == "sha256-CHANNEL"
      && !(d.channel ? rev)
      # A file that is not unpacked has a flat hash, no narHash.
      && d.file.fetch ? file
      && !(d.file ? narHash);

    pinsNpinsSourceRecord =
      let
        s = (core.pins.npins ./fixtures/pins-npins).sources;
      in
      s.github.pin == {
        system = "npins";
        files = {
          refs = "sources.json";
          revisions = "sources.json";
        };
        dir = ./fixtures/pins-npins;
        url = "https://github.com/nixos/nixpkgs.git";
        hash = "sha256-GITHUB";
        rev = "5555555555555555555555555555555555555555";
        narHash = "sha256-GITHUB";
      };

    pinsNpinsRefusals =
      throws (core.pins.npins ./fixtures/pins-npins).sources.container.pin
      && throws (core.pins.npins ./fixtures/pins-npins-v5).sources
      && throws (core.pins.npins ./fixtures/pins-plain-dir).sources;

    pinsGitRootOutsideGit =
      core.pins.gitRoot ./fixtures/pins-plain-dir == {
        outPath = ./fixtures/pins-plain-dir;
        dirty = false;
        rev = null;
        shortRev = null;
        dirtyRev = null;
        dirtyShortRev = null;
        lastModified = null;
        lastModifiedDate = null;
        narHash = null;
      };

    # The readers are an entry of every mkLib composition.
    pinsComposedIntoMkLib =
      let
        composed = core.mkLib {
          sources = { };
          defaultEcosystemSrc.nixpkgs-lib = ./fixtures/nixpkgs-lib-stub;
        };
      in
      builtins.attrNames composed.caisson-core.pins == [
        "flake"
        "flake-compat"
        "gitRoot"
        "npins"
      ];

  };

  failures = builtins.filter (n: results.${n} != true) (builtins.attrNames results);

in
{
  inherit results failures;
  ok = failures == [ ];
  summary =
    if failures == [ ] then
      "ok: ${toString (builtins.length (builtins.attrNames results))} tests passed"
    else
      throw "caisson-core tests failed: ${builtins.concatStringsSep ", " failures}";
}
