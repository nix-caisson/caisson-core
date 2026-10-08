# SPDX-License-Identifier: MIT
#
# `caisson-core.attrsets`: the attribute set functions that code
# written on caisson-core needs and `builtins` lacks. Each behaves as
# the function of the same name in the library of nixpkgs does; this
# file imports nothing.
{ ... }:
let

  # The attribute set with a name for each element of `names`, whose
  # value is `f` of the name.
  genAttrs =
    names: f:
    builtins.listToAttrs (
      builtins.map (name: {
        inherit name;
        value = f name;
      }) names
    );

  # The attributes of `set` for which `predicate name value` holds.
  # The predicate is forced for every name; the values it keeps stay
  # as lazy as they were.
  filterAttrs =
    predicate: set:
    builtins.removeAttrs set (
      builtins.filter (name: !predicate name set.${name}) (builtins.attrNames set)
    );

in
{
  overlay = _final: prev: {
    caisson-core = (prev.caisson-core or { }) // {
      attrsets = {
        inherit filterAttrs genAttrs;
      };
    };
  };
}
