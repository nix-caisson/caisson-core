#!/bin/sh
# Runs the hermetic test suite; used locally and handy for CI parity.
cd "$(dirname "$0")" || exit 1
exec nix eval -f tests summary
