# SPDX-License-Identifier: MIT
#
# `caisson-core.lists`: the list functions that code written on
# caisson-core needs and `builtins` lacks. With `attrsets`, `strings`
# and `functions` beside it, such code (a builder of configurations,
# say) can be composed in a library that holds no other library. Each
# behaves as the function of the same name in the library of nixpkgs
# does; this file imports nothing.
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
      builtins.throw "caisson-core.lists.last: the list is empty"
    else
      builtins.elemAt list (builtins.length list - 1);
  init =
    list:
    if list == [ ] then
      builtins.throw "caisson-core.lists.init: the list is empty"
    else
      builtins.genList (builtins.elemAt list) (builtins.length list - 1);

in
{
  overlay = _final: prev: {
    caisson-core = (prev.caisson-core or { }) // {
      lists = {
        inherit
          init
          last
          unique
          zipListsWith
          ;
      };
    };
  };
}
