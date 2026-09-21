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

    replacementInheritsSlot =
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
        inputs.nixpkgs-lib = "I";
      } == "E";

    resolveDefaultBeatsInput =
      resolve {
        name = "nixpkgs-lib";
        defaults.nixpkgs-lib = "D";
        inputs.nixpkgs-lib = "I";
      } == "D";

    resolveInputByExactName =
      resolve {
        name = "nixpkgs-lib";
        inputs = {
          nixpkgs-lib = "I";
          nixpkgs = "wrong";
        };
      } == "I";

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

    partitionExtraInputsLoadsLockedSubflake = core.partitionExtraInputs ./fixtures/deps-flake == { };

    # Lifecycle: mkLib and the registration machinery.

    lifecycleMkLibRefusesTheOldEcosystemsName = throws (
      core.mkLib {
        inputs = { };
        ecosystems = { };
      }
    );

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
          inputs = { };
          libOverlays = mkLibOverlay: {
            main = mkLibOverlay (
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
        composed = core.mkLib { inputs = { }; };
      in
      builtins.isAttrs composed.caisson-core.libManifest && !(composed ? extend);

    lifecycleComposesOverlays =
      let
        composed = core.mkLib {
          inputs = { };
          libOverlays = mkLibOverlay: {
            a-base = mkLibOverlay ({ ... }: { overlay = _final: _prev: { marker = 1; }; });
            b = mkLibOverlay (
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
          inputs = { };
          defaultEcosystemSrc.nixpkgs-lib = ./fixtures/nixpkgs-lib-stub;
          libOverlays = mkLibOverlay: {
            probe = mkLibOverlay (
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
          inputs = { };
          defaultEcosystemSrc.nixpkgs = ./fixtures/nixpkgs-lib-stub;
          libOverlays = mkLibOverlay: {
            probe = mkLibOverlay (
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
          inputs = { };
          libOverlays = mkLibOverlay: {
            probe = mkLibOverlay (
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
          inputs = { };
          defaultEcosystemSrc.nixpkgs-lib = ./fixtures/nixpkgs-lib-stub;
          libOverlays = mkLibOverlay: {
            exported = mkLibOverlay (
              { entries, ... }:
              {
                imports = [ entries.nixpkgs-lib ];
                overlay = final: _prev: { viaUpstream = final.stubIncrement 1; };
              }
            );
          };
        };
        here = core.mkLib {
          inputs = { };
          libOverlays = mkLibOverlay: {
            nixpkgs-lib = mkLibOverlay ({ ... }: { overlay = _final: _prev: { stubIncrement = n: n * 3; }; });
            borrowed = otherTree.caisson-core.libManifest.libOverlays.exported;
          };
        };
      in
      otherTree.viaUpstream == 2 && here.viaUpstream == 3;

    # Two projects each exporting an overlay registered as `default`
    # both compose here: the compose key is the registry name in this
    # tree, not the key the overlay carried from its own.
    lifecycleProjectOverlaysKeepTheirRegistryNames =
      let
        project =
          marker:
          (core.mkLib {
            inputs = { };
            libOverlays = mkLibOverlay: {
              default = mkLibOverlay ({ ... }: { overlay = _final: _prev: { ${marker} = true; }; });
            };
          }).caisson-core.libManifest.libOverlays;
        composed = core.mkLib {
          inputs = { };
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
          inputs = { };
          libOverlays = mkLibOverlay: {
            nixpkgs-lib = mkLibOverlay ({ ... }: { overlay = _final: _prev: { stubIncrement = n: n * 3; }; });
            probe = mkLibOverlay (
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
        builtins.attrNames composed.caisson-core.libManifest.libOverlays == [
          "caisson-core"
          "nixpkgs-lib"
          "probe"
        ];

    lifecycleOverlayClosureCarriesInputs =
      let
        composed = core.mkLib {
          inputs = {
            probe = 42;
          };
          libOverlays = mkLibOverlay: {
            a = mkLibOverlay (
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
          inputs = { };
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
      && builtins.isFunction composed.caisson-core.partitionExtraInputs
      && builtins.isFunction composed.caisson-core.mkModules
      && builtins.isFunction composed.caisson-core.mkLibOverlays
      && composed.caisson-core.modules == { };

    lifecycleOverlayClosureCarriesLib =
      let
        composed = core.mkLib {
          inputs = { };
          libOverlays = mkLibOverlay: {
            marker = mkLibOverlay ({ ... }: { overlay = _final: _prev: { marker = "composed"; }; });
            probe = mkLibOverlay (
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
          inputs = { };
          modules = core.mkModules ./fixtures/modules-dir;
          libOverlays = mkLibOverlay: { classes = mkLibOverlay declaringClasses; };
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
          inputs = { };
          configs = core.mkModules ./fixtures/modules-dir;
          libOverlays = mkLibOverlay: { classes = mkLibOverlay declaringClasses; };
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
          inputs = { };
          modules = core.mkModules ./fixtures/modules-dir;
          libOverlays = mkLibOverlay: {
            classes = mkLibOverlay declaringClasses;
            wrapper = mkLibOverlay wrapping;
          };
          libOverlayImports = overlays: [
            overlays.classes
            overlays.wrapper
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
          inputs = { };
          modules = core.mkModules ./fixtures/modules-dir;
        }).caisson-core.modules.flake;

    readersMkModulesRefusesAStrayFile = throws (
      (core.mkModules ./fixtures/modules-dir-stray) {
        caisson-core.classes.flake.mkModule = path: path;
      }
    );

    readersMkModulesRefusesAnEntryWithoutDefault = throws (
      (core.mkModules ./fixtures/modules-dir-empty-entry) {
        caisson-core.classes.flake.mkModule = path: path;
      }
    );

    readersMkLibOverlaysReadsEntries =
      let
        composed = core.mkLib {
          inputs = { };
          libOverlays = core.mkLibOverlays ./fixtures/lib-overlays-dir;
        };
      in
      composed.fromDefault
      && composed.fromExtra
      &&
        builtins.attrNames composed.caisson-core.libManifest.libOverlays == [
          "caisson-core"
          "default"
          "extra"
          "nixpkgs-lib"
        ];

    readersMkLibOverlaysRefusesAStrayFile = throws (
      (core.mkLibOverlays ./fixtures/lib-overlays-dir-stray) (path: path)
    );

    lifecycleLocalModulesRegister =
      let
        composed = core.mkLib {
          inputs = { };
          modules = composedLib: {
            nixos.local = composedLib.caisson-core.mkModule "nixos" ({ ... }: { config.origin = "local"; });
          };
        };
      in
      composed.caisson-core.modules.nixos.local.config.origin == "local";

    lifecycleConfigsRegister =
      let
        composed = core.mkLib {
          inputs = { };
          configs = composedLib: {
            structural.top = composedLib.caisson-core.mkModule "structural" (
              { ... }: { config.origin = "top"; }
            );
          };
        };
      in
      composed.caisson-core.configs.structural.top.config.origin == "top"
      && composed.caisson-core.libManifest.configs.structural.top.config.origin == "top"
      && (core.mkLib { inputs = { }; }).caisson-core.configs == { };

    lifecycleConfigsRefusesNonFunction =
      !(builtins.tryEval (
        builtins.seq (core.mkLib {
          inputs = { };
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
          inputs = { };
          modules = composedLib: {
            nixos.shared = composedLib.caisson-core.mkModule "nixos" ({ ... }: { config.origin = "local"; });
          };
          libOverlays = mkLibOverlay: { c = mkLibOverlay contributor; };
        };
        registry = composed.caisson-core.modules.nixos;
      in
      registry."other/contributed".config.origin == "contributed"
      && registry.shared.config.origin == "local";

    lifecycleManifestCapturesMkLibFacts =
      let
        theInputs = {
          probe = true;
        };
        composed = core.mkLib {
          inputs = theInputs;
          modules = composedLib: {
            nixos.local = composedLib.caisson-core.mkModule "nixos" ({ ... }: { config.origin = "local"; });
          };
          libOverlays = mkLibOverlay: {
            a = mkLibOverlay ({ ... }: { overlay = _final: _prev: { }; });
          };
        };
        manifest = composed.caisson-core.libManifest;
      in
      builtins.attrNames manifest == [
        "configs"
        "defaultEcosystemSrc"
        "inputs"
        "libOverlays"
        "modules"
        "projects"
        "systems"
      ]
      && manifest.inputs == theInputs
      && manifest.defaultEcosystemSrc == { }
      && manifest.systems == null
      &&
        builtins.attrNames manifest.libOverlays == [
          "a"
          "caisson-core"
          "nixpkgs-lib"
        ]
      && builtins.attrNames manifest.modules == [ "nixos" ]
      && manifest.modules.nixos.local.config.origin == "local";

    # The three phase slots are present on every composed library;
    # mkLib fills the lib one and leaves the other two null.
    lifecycleManifestSlotsArePresentAndNullUntilFilled =
      let
        composed = core.mkLib {
          inputs = { };
        };
      in
      builtins.isAttrs composed.caisson-core.libManifest
      && composed.caisson-core.pkgsManifest == null
      && composed.caisson-core.evalManifest == null;

    lifecycleSystemsAreDeclaredOnMkLib =
      let
        composed = core.mkLib {
          inputs = { };
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
          inputs = { };
          systems = "x86_64-linux";
        }
      )
      && throws (
        core.mkLib {
          inputs = { };
          systems = [ 1 ];
        }
      );

    lifecycleEcosystemDeclarationsJoinTheManifest =
      let
        composed = core.mkLib {
          inputs = { };
          defaultEcosystemSrc = {
            nixpkgs = "/probe-nixpkgs";
          };
        };
      in
      composed.caisson-core.libManifest.defaultEcosystemSrc.nixpkgs == "/probe-nixpkgs";

    lifecycleDefaultEcosystemSrcMustBeAnAttrset = throws (
      core.mkLib {
        inputs = { };
        defaultEcosystemSrc = 42;
      }
    );

    lifecycleInjectedMkLibIsTheSameMkLib =
      let
        outer = core.mkLib { inputs = { }; };
        inner = outer.caisson-core.mkLib {
          inputs = { };
          defaultEcosystemSrc.nixpkgs-lib = ./fixtures/nixpkgs-lib-stub;
          libOverlays = mkLibOverlay: {
            probe = mkLibOverlay (
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
          inputs = { };
          projects = {
            inherit dep;
          };
        };
      in
      composed.greet "world" == "hello, world"
      && composed.caisson-core.modules.nixos."dep/service".config.origin == "dep"
      && builtins.attrNames composed.caisson-core.libManifest.projects == [ "dep" ]
      # The manifest dictionaries carry the registered union, so the
      # export side sees project entries like hand-registered ones.
      &&
        builtins.attrNames composed.caisson-core.libManifest.libOverlays == [
          "caisson-core"
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
          inputs = { };
          projects = {
            inherit dep;
          };
          libOverlays = mkLibOverlay: {
            local = mkLibOverlay ({ ... }: { overlay = _final: _prev: { fromLocal = true; }; });
          };
          # Per-item choice over the combined dictionary: prefixed
          # project names beside local short names.
          libOverlayImports = overlays: [ overlays.local ];
        };
      in
      composed.fromLocal
      && !(composed ? fromDep)
      # Selection controls application only; the unselected project
      # overlay stays registered in the manifest dictionary.
      &&
        builtins.attrNames composed.caisson-core.libManifest.libOverlays == [
          "caisson-core"
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
          inputs = { };
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

    lifecycleProjectsMustBeAnAttrset = throws (
      core.mkLib {
        inputs = { };
        projects = 42;
      }
    );

    lifecycleCoreOverlayComposesAsEntry =
      let
        machinery = core.mkCoreOverlay { inputs = { }; };
        r = compose {
          entries = [
            {
              key = "test.machinery";
              imports = [ ];
              overlay = machinery.overlay;
            }
          ];
        };
      in
      builtins.isFunction r.lib.caisson-core.mkLibOverlay && r.lib.caisson-core.modules == { };

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
