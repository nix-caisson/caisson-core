# SPDX-License-Identifier: MIT
{ ... }:
{
  overlay = _final: prev: {
    probe = (prev.probe or { }) // {
      greeting = "from base";
      # A computed name: mapAttrs results carry no binding position.
      made = (builtins.mapAttrs (_: v: v) { inner = 1; }).inner;
    }
    // builtins.mapAttrs (_: v: v) { computed = "from base"; };
  };
}
