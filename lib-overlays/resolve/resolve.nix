# SPDX-License-Identifier: MIT
#
# Layered ecosystem-source resolution. It can never throw or format a
# message, because a full miss is the interpretable value null, left
# to the caller to interpret. Priority: the explicit argument, then
# the client's declared defaults, then the source with exactly the
# declared name among the tree's pinned sources. A plain function, so
# mkLib can resolve the `nixpkgs-lib` source before the fixpoint it is
# building exists.
{
  name,
  explicit ? null,
  defaults ? { },
  sources ? { },
}:
if explicit != null then
  explicit
else if builtins.hasAttr name defaults then
  defaults.${name}
else if builtins.hasAttr name sources then
  sources.${name}
else
  null
