# SPDX-License-Identifier: MIT
#
# npins' sources.json, read as data, and the fetch each pin needs.
# The fetches are those npins' generated default.nix performs with
# the builtin fetchers, so a pin read here is the tree npins would
# give. Only format version 8 is read, the version npins writes and
# its generated default.nix accepts.
#
# `describe` is pure (JSON to descriptors); `fetch` fetches one
# descriptor. Builtins only.
let

  supportedVersion = 8;

  # npins records hashes as SRI strings in version 8; anything else is
  # converted, so `narHash` is SRI, as on a flake input.
  toSri =
    hash:
    if builtins.match "[a-z0-9]+-.*" hash != null then
      hash
    else
      builtins.convertHash {
        inherit hash;
        hashAlgo = "sha256";
        toHashFormat = "sri";
      };

  repositoryUrl =
    name: repository:
    if repository.type == "Git" then
      repository.url
    else if repository.type == "GitHub" then
      "https://github.com/${repository.owner}/${repository.repo}.git"
    else if repository.type == "GitLab" then
      "${repository.server}/${repository.repo_path}.git"
    else if repository.type == "Forgejo" then
      "${repository.server}/${repository.owner}/${repository.repo}.git"
    else
      throw "caisson-core: pins.npins: pin `${name}` names a repository of type `${repository.type}`, which is not supported";

  # One descriptor per pin:
  #
  #   type      the npins pin type
  #   url       the repository or URL the pin names
  #   rev       the revision, for a git pin
  #   hash      the hash npins recorded, as written
  #   narHash   that hash as SRI, when it is the hash of an unpacked
  #             tree (every pin but a file that is not unpacked)
  #   fetch     what `fetch` does: { tarball = { url; sha256; }; },
  #             { git = { url; rev; narHash; submodules; name; }; } or
  #             { file = { url; sha256; }; }
  describePin =
    name: spec:
    let
      type = spec.type or (throw "caisson-core: pins.npins: pin `${name}` has no type");
      tree = fetch: {
        narHash = toSri spec.hash;
        inherit fetch;
      };
      file = url: {
        fetch.file = {
          inherit url;
          sha256 = spec.hash;
        };
      };
    in
    {
      inherit type;
      inherit (spec) hash;
    }
    // (
      if type == "Git" || type == "GitRelease" then
        let
          url = repositoryUrl name spec.repository;
          submodules = spec.submodules or false;
        in
        {
          inherit url;
          rev = spec.revision;
        }
        // tree (
          if (spec.url or null) != null && !submodules then
            {
              tarball = {
                url = spec.url;
                sha256 = spec.hash;
              };
            }
          else
            {
              git = {
                inherit url submodules;
                rev = spec.revision;
                narHash = spec.hash;
                name = "source";
              };
            }
        )
      else if type == "Channel" then
        {
          inherit (spec) url;
        }
        // tree {
          tarball = {
            inherit (spec) url;
            sha256 = spec.hash;
          };
        }
      else if type == "Url" || type == "MutableUrl" then
        {
          inherit (spec) url;
        }
        // (
          if spec.unpack or true then
            tree {
              tarball = {
                inherit (spec) url;
                sha256 = spec.hash;
              };
            }
          else
            file spec.url
        )
      else if type == "PyPi" then
        {
          inherit (spec) url;
        }
        // file spec.url
      else
        throw ''
          caisson-core: pins.npins: pin `${name}` is of type `${type}`, which the
          builtin fetchers cannot produce (the supported types are Git,
          GitRelease, Channel, Url, MutableUrl and PyPi).
        ''
    );

  describe =
    what: data:
    if (data.version or null) == supportedVersion then
      builtins.mapAttrs describePin (data.pins or { })
    else
      throw ''
        caisson-core: ${what} reads an npins sources.json of format version
        ${toString (data.version or "none")}, and only version ${toString supportedVersion} is supported.
        Run `npins upgrade`.
      '';

  fetch =
    descriptor:
    let
      how = descriptor.fetch;
    in
    if how ? tarball then
      { outPath = builtins.fetchTarball how.tarball; }
    else if how ? git then
      builtins.fetchGit how.git
    else
      {
        outPath = builtins.fetchurl (how.file // { name = "source"; });
      };

in
{
  inherit describe fetch supportedVersion;
}
