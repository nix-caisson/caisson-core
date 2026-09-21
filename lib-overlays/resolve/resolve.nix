# SPDX-License-Identifier: MIT
#
# Layered ecosystem-source resolution. It can never throw or format a
# message, because a full miss is the interpretable value null, left
# to the caller to interpret. Priority: the explicit argument, then
# the client's declared defaults, then an input with exactly the
# declared name. A plain function, so mkLib can resolve the
# `nixpkgs-lib` source before the fixpoint it is building exists.
{
  name,
  explicit ? null,
  defaults ? { },
  inputs ? { },
}:
if explicit != null then
  explicit
else if builtins.hasAttr name defaults then
  defaults.${name}
else if builtins.hasAttr name inputs then
  inputs.${name}
else
  null
