# SPDX-License-Identifier: MIT
#
# The flake lock file, read as data: what each of a flake's inputs is
# locked to, following `follows` the way Nix and flake-compat do. Both
# flake pin readers use it: `pins.flake` for the refs and locked
# hashes the lock records (the trees themselves come from Nix), and
# `pins.flake-compat` for everything, fetching what it describes.
#
# Pure: nothing here fetches or imports a flake. Builtins only.
let

  # The lock of a flake directory, or null when the flake has none (a
  # flake without inputs need not have a lock).
  readLock =
    dir:
    let
      file = dir + "/flake.lock";
    in
    if builtins.pathExists file then builtins.fromJSON (builtins.readFile file) else null;

  checkVersion =
    what: lock:
    if lock.version >= 5 && lock.version <= 7 then
      lock
    else
      throw ''
        caisson-core: ${what} reads a flake.lock of version ${toString lock.version},
        and only versions 5 to 7 are supported. Relock it with a current Nix
        (`nix flake lock`).
      '';

  # An input spec in a lock node is either a node name or, for a
  # `follows`, a path of input names from the root node. The node the
  # spec lands on, as flake-compat's resolveInput and getInputByPath.
  resolveInput =
    lock: spec: if builtins.isList spec then inputByPath lock lock.root spec else spec;

  inputByPath =
    lock: nodeName: path:
    if path == [ ] then
      nodeName
    else
      inputByPath lock (resolveInput lock lock.nodes.${nodeName}.inputs.${builtins.head path}) (
        builtins.tail path
      );

  # One descriptor per input of the root node:
  #
  #   node       the lock node the input lands on
  #   follows    the path of input names from the root, for an input
  #              declared as a `follows`; absent otherwise
  #   locked     the node's `locked` attrs (what a fetch reproduces)
  #   original   the node's `original` attrs (the ref as written)
  #   flake      whether the input is a flake (`flake = false` inputs
  #              are plain source trees)
  #   relative   whether the node is a relative `path:` input, located
  #              inside its parent's tree rather than fetched
  #   parent     for a relative node, the path of input names from the
  #              root to the node whose tree it lies in ([ ] for the
  #              root itself)
  descriptors =
    lock:
    let
      rootNode = lock.nodes.${lock.root};
    in
    builtins.mapAttrs (
      _name: spec:
      let
        nodeName = resolveInput lock spec;
        node = lock.nodes.${nodeName};
        locked = node.locked or { };
      in
      {
        node = nodeName;
        inherit locked;
        original = node.original or { };
        flake = node.flake or true;
        relative = (locked.type or null) == "path" && builtins.substring 0 1 (locked.path or "/") != "/";
        parent = node.parent or [ ];
      }
      // (if builtins.isList spec then { follows = spec; } else { })
    ) (rootNode.inputs or { });

  # A flake reference rendered as a string, from the `original` attrs
  # of a lock node. Uses the evaluator's renderer where it has one (it
  # needs the flakes feature); otherwise renders the common forms the
  # same way.
  refToString =
    ref: if builtins ? flakeRefToString then builtins.flakeRefToString ref else renderRef ref;

  query =
    attrs:
    let
      value = v: if v == true then "1" else if v == false then "0" else toString v;
      pairs = builtins.map (n: "${n}=${value attrs.${n}}") (builtins.attrNames attrs);
    in
    if pairs == [ ] then "" else "?" + builtins.concatStringsSep "&" pairs;

  renderRef =
    ref:
    let
      type = ref.type or null;
      rest = builtins.removeAttrs ref;
    in
    if type == "github" || type == "gitlab" || type == "sourcehut" then
      "${type}:${ref.owner}/${ref.repo}"
      + (
        if ref ? rev then
          "/${ref.rev}"
        else if ref ? ref then
          "/${ref.ref}"
        else
          ""
      )
      + query (rest [
        "type"
        "owner"
        "repo"
        "ref"
        "rev"
      ])
    else if type == "git" then
      "git+${ref.url}"
      + query (rest [
        "type"
        "url"
      ])
    else if type == "path" then
      "path:${ref.path}"
      + query (rest [
        "type"
        "path"
      ])
    else if type == "indirect" then
      "flake:${ref.id}"
      + (if ref ? ref then "/${ref.ref}" else "")
      + (if ref ? rev then "/${ref.rev}" else "")
    else if type == "tarball" || type == "file" then
      ref.url
    else
      throw "caisson-core: cannot render a flake reference of type `${toString type}`";

in
{
  inherit
    readLock
    checkVersion
    descriptors
    resolveInput
    inputByPath
    refToString
    renderRef
    ;
}
