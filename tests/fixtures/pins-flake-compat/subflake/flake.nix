# SPDX-License-Identifier: MIT
# A relative path input that is a flake: pins.flake-compat hands it over
# with its outputs, as a partition reads `inputs.<name>.flakeModule`.
{
  outputs = _: { flakeModule = "the-module"; };
}
