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

    lifecycleMkLibRequiresBaseLib = throws (core.mkLib { inputs = { }; });

    lifecycleComposesOverlays =
      let
        composed = core.mkLib {
          inputs = { };
          baseLib = {
            marker = 1;
          };
          libOverlays = mkLibOverlay: {
            a = mkLibOverlay (
              { ... }:
              {
                overlay = _final: prev: { x = prev.marker + 1; };
              }
            );
          };
        };
      in
      composed.marker == 1 && composed.x == 2;

    lifecycleOverlayClosureCarriesInputs =
      let
        composed = core.mkLib {
          inputs = {
            probe = 42;
          };
          baseLib = { };
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
          baseLib = { };
        };
      in
      builtins.isFunction composed.caisson-core.mkLib
      && builtins.isFunction composed.caisson-core.mkLibOverlay
      && builtins.isFunction (composed.caisson-core.mkModule "nixos")
      && builtins.isFunction composed.caisson-core.importApply
      && builtins.isFunction composed.caisson-core.compose
      && builtins.isFunction composed.caisson-core.resolve
      && builtins.isFunction composed.caisson-core.callConsumerFlake
      && builtins.isFunction composed.caisson-core.partitionExtraInputs
      && composed.caisson-core.modules == { };

    lifecycleLocalModulesRegister =
      let
        composed = core.mkLib {
          inputs = { };
          baseLib = { };
          modules = composedLib: {
            nixos.local = composedLib.caisson-core.mkModule "nixos" ({ ... }: { config.origin = "local"; });
          };
        };
      in
      composed.caisson-core.modules.nixos.local.config.origin == "local";

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
          baseLib = { };
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
          baseLib = { };
          modules = composedLib: {
            nixos.local = composedLib.caisson-core.mkModule "nixos" ({ ... }: { config.origin = "local"; });
          };
          libOverlays = mkLibOverlay: {
            a = mkLibOverlay ({ ... }: { overlay = _final: _prev: { }; });
          };
        };
        manifest = composed.caisson-core.manifest;
      in
      builtins.attrNames manifest == [
        "ecosystems"
        "inputs"
        "libOverlays"
        "modules"
        "projects"
      ]
      && manifest.inputs == theInputs
      && manifest.ecosystems == { }
      && builtins.attrNames manifest.libOverlays == [ "a" ]
      && builtins.attrNames manifest.modules == [ "nixos" ]
      && manifest.modules.nixos.local.config.origin == "local";

    lifecycleEcosystemDeclarationsJoinTheManifest =
      let
        composed = core.mkLib {
          inputs = { };
          baseLib = { };
          ecosystems = {
            nixpkgs = "/probe-nixpkgs";
          };
        };
      in
      composed.caisson-core.manifest.ecosystems.nixpkgs == "/probe-nixpkgs";

    lifecycleEcosystemsMustBeAnAttrset = throws (
      core.mkLib {
        inputs = { };
        baseLib = { };
        ecosystems = 42;
      }
    );

    lifecycleInjectedMkLibDefaultsToCompositionBase =
      let
        outer = core.mkLib {
          inputs = { };
          baseLib = {
            marker = "outer-base";
          };
        };
        inner = outer.caisson-core.mkLib { inputs = { }; };
      in
      inner.marker == "outer-base";

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
          baseLib = { };
          projects = {
            inherit dep;
          };
        };
      in
      composed.greet "world" == "hello, world"
      && composed.caisson-core.modules.nixos."dep/service".config.origin == "dep"
      && builtins.attrNames composed.caisson-core.manifest.projects == [ "dep" ]
      # The manifest dictionaries carry the registered union, so the
      # export side sees project entries like hand-registered ones.
      && builtins.attrNames composed.caisson-core.manifest.libOverlays == [ "dep/greeter" ]
      && composed.caisson-core.manifest.modules.nixos."dep/service".config.origin == "dep";

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
          baseLib = { };
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
      && builtins.attrNames composed.caisson-core.manifest.libOverlays == [
        "dep/marker"
        "local"
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
          baseLib = { };
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
      && composed.caisson-core.manifest.modules.nixos."dep/service".config.origin == "local";

    lifecycleProjectsMustBeAnAttrset = throws (
      core.mkLib {
        inputs = { };
        baseLib = { };
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
