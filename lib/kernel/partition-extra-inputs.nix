# SPDX-License-Identifier: MIT
# The read-only-eval-safe replacement for flake-parts partitions'
# `extraInputsFlake`: load a lockfile'd subflake dir (e.g. a repo's
# tests/dependencies) and return its inputs, for `partitions.<name>.extraInputs`.
#
#   partitions.checks.extraInputs = caisson-core.partitionExtraInputs ../../tests/dependencies;
#
# `extraInputsFlake` routes the same path through flake-parts' vendored
# flake-compat, which imports the subflake's flake.nix through a coerced
# store-path string — a store object the evaluation itself must create, which
# `nix flake check --no-build` (read-only eval store) cannot, failing
# with "path '…' is not valid" unless the object was pre-materialized. Our
# vendored copy imports via the original path value instead (see
# vendor/flake-compat), so the load works in any evaluation mode.
#
# COVERAGE CONSTRAINT: the vendored fix patches the ROOT import only. The
# extra-inputs flake's lock must hold only remote (github/git/tarball…)
# inputs — a RELATIVE PATH input (`path:./sub`) is imported through the
# root's coerced copy and resurrects the read-only failure (verified).
# Locked remote inputs are fine: fetchTree materializes them even under
# --no-build. Keep tests/dependencies-style flakes free of relative path
# inputs, or extend the vendor patch to thread path values through node
# resolution first.
src:
(import ../../vendor/flake-compat {
  inherit src;
  # Mirrors flake-parts extras/partitions.nix `get-flake`: partition input
  # loading is pure; nothing may consult the eval system.
  system = throw "caisson-core.partitionExtraInputs: pure flake-compat use; no system available";
}).outputs.inputs
