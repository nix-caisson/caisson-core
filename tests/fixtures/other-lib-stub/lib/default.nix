# SPDX-License-Identifier: MIT
#
# A second library source, told apart from `lib-stub` by what
# `stubIncrement` adds, so a test can show which source a composition
# loaded.
{
  stubIncrement = n: n + 10;
}
