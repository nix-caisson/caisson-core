# SPDX-License-Identifier: MIT
# Minimal reimplementation of flake output wiring: applies a flake's
# outputs function to explicitly provided, already-wired inputs. No lock
# handling and no fetching: every input must be a fully constructed
# flake (itself built with this function) or a plain source path for
# non-flake inputs. The shared kernel under callConsumerFlake and the
# eval-weight harness. This file must stay self-contained: eval-weight
# imports it from inside the measurement sandbox by path, without lib
# (routing measured subjects through the composed lib would leak the
# framework's own bootstrap cost into the measurements).
{
  src,
  inputs ? { },
  # Flakes normally expose sourceInfo attrs (lastModified, rev, ...) on
  # self; provide them here if the subject's evaluation reads them.
  sourceInfo ? { },
}:
let
  flake = import (src + "/flake.nix");
  outputs = flake.outputs (inputs // { inherit self; });
  self =
    outputs
    // sourceInfo
    // {
      inherit inputs outputs;
      outPath = src;
      _type = "flake";
    };
in
self
