# SPDX-License-Identifier: MIT
#
# `caisson-core.functions`: reading and stating the arguments a
# function names, which code written on caisson-core needs and
# `builtins` covers for plain functions alone. Each behaves as the
# function of the same name in the library of nixpkgs does; this file
# imports nothing.
{ ... }:
let

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
      functions = {
        inherit functionArgs setFunctionArgs;
      };
    };
  };
}
