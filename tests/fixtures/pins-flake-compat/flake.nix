# SPDX-License-Identifier: MIT
# pins.flake-compat test fixture: a relative path input that is not a
# flake and one that is (both read without fetching), a follows of the
# first, a remote input (described, never fetched by the suite), and an
# input landing on a relative path inside another input (refused).
{
  inputs = {
    local.url = "path:./sub";
    local.flake = false;
    localFlake.url = "path:./subflake";
    alias.follows = "local";
    remote.url = "github:example/remote/v1";
    nested.follows = "remote/inner";
  };
  outputs = _: { };
}
