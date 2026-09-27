# SPDX-License-Identifier: MIT
# pins.flake-compat test fixture: a relative path input (read without
# fetching), a follows of it, a remote input (described, never fetched
# by the suite), and an input landing on a relative path inside another
# input (refused).
{
  inputs = {
    local.url = "path:./sub";
    alias.follows = "local";
    remote.url = "github:example/remote/v1";
    nested.follows = "remote/inner";
  };
  outputs = _: { };
}
