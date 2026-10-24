# SPDX-License-Identifier: MIT
#
# The names of the pinned sources a selection chooses. A selection is a
# function of the `sources` of a tree, such as `defaultEcosystemSrc` on
# mkLib or `ecosystemSrc` on a configuration. `tagged` is a copy of
# `sources` in which each source that is an attribute set carries its
# name. Applying the selection to that copy returns the same choice,
# and `nameOf` reads the name back from what it returned: the name of a
# source the selection returned as it is, and null for a value it built
# in another way, such as a directory inside a source. The copy forces
# a source only where the selection reads it. A plain file of builtins,
# so mkLib can name the sources before the fixpoint it builds exists.
let
  tag = "_caissonSourceName";
in
{
  tagged = builtins.mapAttrs (
    name: source: if builtins.isAttrs source then source // { ${tag} = name; } else source
  );
  nameOf = value: if builtins.isAttrs value then value.${tag} or null else null;
}
