# SPDX-License-Identifier: MIT
#
# The kernel: minimal flake-output wiring over explicitly provided,
# already-wired inputs (no lock handling, no fetching), the
# read-only-eval-safe partition extra-inputs loader, and the consumer
# flake caller built on the first. call-flake.nix and
# partition-extra-inputs.nix are self-contained on purpose; see their
# headers.
{ ... }:
let

  callFlake = import ./call-flake.nix;
  partitionExtraInputs = import ./partition-extra-inputs.nix;

  # Evaluate a consumer-style flake from source with explicitly
  # supplied inputs. The flake's declared inputs resolve by name:
  # `overrides` first, then `follows` chains through the other
  # resolved inputs, then `pool`; anything else throws, naming the
  # input. The self fixpoint and decoration (`inputs`, `outputs`,
  # `outPath`, `_type`) are handled by callFlake. Nothing is fetched:
  # URL-declared inputs must be supplied (test-only pins
  # conventionally come from a tests/dependencies flake). Locks,
  # follows across unsupplied inputs, and sourceInfo are not consulted
  # or emulated.
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

in
{
  overlay = _final: prev: {
    caisson-core = (prev.caisson-core or { }) // {
      inherit callFlake partitionExtraInputs callConsumerFlake;
    };
  };
}
