# SPDX-License-Identifier: MIT
#
# `caisson-core.util`: the few list, attribute set, string and function
# helpers that code written on caisson-core needs and `builtins` lacks.
# They exist so that such code (a builder of configurations, say) can
# be composed in a library that holds no other library. Each behaves
# as the function of the same name in the library of nixpkgs does for
# the arguments described here; this file imports nothing.
{ ... }:
let

  # The elements of `list` without repeats, each where it first
  # occurs.
  unique =
    list:
    builtins.foldl' (acc: element: if builtins.elem element acc then acc else acc ++ [ element ]) [ ] list;

  # `f` applied to the elements of two lists pairwise, as far as the
  # shorter list goes.
  zipListsWith =
    f: first: second:
    let
      a = builtins.length first;
      b = builtins.length second;
    in
    builtins.genList (n: f (builtins.elemAt first n) (builtins.elemAt second n)) (if a < b then a else b);

  # The last element of a list, and the list without it. Both refuse
  # the empty list.
  last =
    list:
    if list == [ ] then
      builtins.throw "caisson-core.util.last: the list is empty"
    else
      builtins.elemAt list (builtins.length list - 1);
  init =
    list:
    if list == [ ] then
      builtins.throw "caisson-core.util.init: the list is empty"
    else
      builtins.genList (builtins.elemAt list) (builtins.length list - 1);

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

  # Whether `infix` occurs in `string`. `builtins.split` takes a
  # regular expression, so every character of `infix` is written as a
  # bracket expression that matches only itself.
  hasInfix =
    infix: string:
    let
      characters = builtins.genList (i: builtins.substring i 1 infix) (builtins.stringLength infix);
      literal =
        character:
        if character == "^" then
          "\\^"
        else if character == "\\" then
          "\\\\"
        else if character == "]" then
          "[]]"
        else
          "[${character}]";
      pattern = builtins.concatStringsSep "" (builtins.map literal characters);
    in
    infix == "" || builtins.length (builtins.split pattern string) > 1;

  # The arguments a function names, as `builtins.functionArgs` gives
  # them, for a plain function and for a function wrapped by
  # `setFunctionArgs` alike. A wrapped function is an attribute set
  # that is callable through `__functor` and states its arguments in
  # `__functionArgs`; this is the convention of the library of
  # nixpkgs, so a function wrapped here reads the same there.
  functionArgs =
    f:
    if builtins.isAttrs f && f ? __functor then
      f.__functionArgs or (functionArgs (f.__functor f))
    else
      builtins.functionArgs f;
  setFunctionArgs = f: args: {
    __functor = _self: f;
    __functionArgs = args;
  };

in
{
  overlay = _final: prev: {
    caisson-core = (prev.caisson-core or { }) // {
      util = {
        inherit
          filterAttrs
          functionArgs
          genAttrs
          hasInfix
          init
          last
          setFunctionArgs
          unique
          zipListsWith
          ;
      };
    };
  };
}
