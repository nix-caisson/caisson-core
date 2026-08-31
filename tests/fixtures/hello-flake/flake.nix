# SPDX-License-Identifier: MIT
# Kernel test fixture: a tiny flake whose outputs read an input and self.
{
  description = "kernel fixture";
  outputs =
    { self, greeting }:
    {
      message = "${greeting.text}, kernel";
      selfPath = self.outPath;
      viaSelf = self.message;
    };
}
