# SPDX-License-Identifier: MIT
# pins.flake test fixture: the tree of a flake whose `self` a fake
# inputs attrset points at; only its flake.lock is read.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    follower.follows = "nixpkgs";
    nonflake = {
      url = "git+https://example.com/nonflake.git?ref=main";
      flake = false;
    };
    overridden.url = "github:example/overridden";
  };
  outputs = _: { };
}
