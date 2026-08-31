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
        r = compose { entries = [ a b ]; };
      in
      r.lib.x == 1 && r.lib.y == 2;

    finalSeesFixpointRegardlessOfOrder =
      let
        a = entry "test.a" [ ] (_final: _prev: { x = 1; });
        b = entry "test.b" [ ] (final: _prev: { y = final.x + 1; });
        r = compose { entries = [ b a ]; };
      in
      r.lib.y == 2;

    dedupDiamondAppliesOnce =
      let
        a = entry "test.a" [ base ] (_final: _prev: { x = 1; });
        b = entry "test.b" [ base ] (_final: _prev: { y = 2; });
        r = compose { entries = [ a b ]; };
      in
      r.lib.applications == 1;

    lastWinsValueFirstWinsPosition =
      let
        v1 = entry "test.k" [ ] (_final: _prev: { v = 1; });
        other = entry "test.other" [ ] (_final: _prev: { o = true; });
        v2 = entry "test.k" [ ] (_final: _prev: { v = 2; });
        r = compose { entries = [ v1 other v2 ]; };
      in
      r.lib.v == 2 && r.meta.order == [ "test.k" "test.other" ];

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
        k1 = entry "test.k" [ ] (_final: prev: { sawN = prev ? n; v = 1; });
        n = entry "test.n" [ ] (_final: _prev: { n = true; });
        k2 = entry "test.k" [ n ] (_final: prev: { sawN = prev ? n; v = 2; });
        r = compose { entries = [ k1 k2 ]; };
      in
      r.lib.v == 2 && r.lib.n && !r.lib.sawN && r.meta.order == [ "test.k" "test.n" ];

    cycleTerminatesDeterministically =
      let
        a = entry "test.ca" [ b ] (_final: _prev: { ca = true; });
        b = entry "test.cb" [ a ] (_final: _prev: { cb = true; });
        r = compose { entries = [ a ]; };
      in
      r.lib.ca && r.lib.cb && r.meta.order == [ "test.cb" "test.ca" ];

    keylessAppliesAfterKeyedWorld =
      let
        keyed = entry "test.keyed" [ ] (_final: _prev: { fromKeyed = true; });
        anon = {
          key = null;
          imports = [ ];
          overlay = _final: prev: { anonSawKeyed = prev ? fromKeyed; };
        };
        r = compose { entries = [ anon keyed ]; };
      in
      r.lib.anonSawKeyed && r.meta.tailLength == 1;

    keylessStacksOnRepetition =
      let
        anon = {
          key = null;
          imports = [ ];
          overlay = _final: prev: { count = (prev.count or 0) + 1; };
        };
        r = compose { entries = [ anon anon ]; };
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
          inputs.greeting = { text = "hello"; };
          sourceInfo.rev = "fixture";
        };
      in
      wired.message == "hello, kernel"
      && wired.viaSelf == "hello, kernel"
      && wired.selfPath == ./fixtures/hello-flake
      && wired.rev == "fixture"
      && wired._type == "flake"
      && wired.inputs.greeting.text == "hello";

    partitionExtraInputsLoadsLockedSubflake =
      core.partitionExtraInputs ./fixtures/deps-flake == { };

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
