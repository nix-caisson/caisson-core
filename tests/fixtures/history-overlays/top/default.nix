# SPDX-License-Identifier: MIT
{ ... }:
{
  overlay = _final: prev: {
    probe = prev.probe // {
      greeting = "from top";
    };
  };
}
