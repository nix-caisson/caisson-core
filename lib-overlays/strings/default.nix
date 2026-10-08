# SPDX-License-Identifier: MIT
#
# `caisson-core.strings`: the string function that code written on
# caisson-core needs and `builtins` lacks. It behaves as the function
# of the same name in the library of nixpkgs does; this file imports
# nothing.
{ ... }:
let

  # Whether `infix` occurs in `string`. `builtins.split` takes a
  # regular expression, so every character of `infix` is written in
  # a form that matches only itself.
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

in
{
  overlay = _final: prev: {
    caisson-core = (prev.caisson-core or { }) // {
      strings = {
        inherit hasInfix;
      };
    };
  };
}
