# caisson-core

A minimal engine for composing library overlays: identity,
replacement, and deterministic order, implemented over plain Nix
builtins.

caisson-core has **zero flake inputs** and its library code references
nothing but `builtins`. It is the foundation layer of the caisson
family; it is useful on its own to anyone who wants to compose an
extensible library out of overlay-shaped pieces without depending on
nixpkgs, flake-parts, or any other flake.

## The entry contract

The unit of composition is an *entry*:

```nix
{
  key = "example.base";   # stable identity: a string, or null
  imports = [ ];          # entries this entry depends on
  overlay = final: prev: { greet = name: "hello, ${name}"; };
}
```

`compose` takes a list of entries and produces the composed library
plus composition metadata:

```nix
let
  core = (builtins.getFlake "github:nix-caisson/caisson-core").lib.caisson-core;

  base = {
    key = "example.base";
    imports = [ ];
    overlay = final: prev: { greet = name: "hello, ${name}"; };
  };

  loud = {
    key = "example.loud";
    imports = [ base ];
    overlay = final: prev: { greet = name: "${prev.greet name}!"; };
  };
in
(core.compose { entries = [ loud ]; }).lib.greet "world"
# => "hello, world!"
```

## Semantics

- **Imports are reachability.** Listing an entry pulls its transitive
  imports into the composition. Entries are collected by a
  depth-first, post-order walk, so an entry's imports precede it.
- **The key is identity.** A keyed entry appears once no matter how
  many entries import it. The *first* occurrence of a key fixes its
  position; the *last* occurrence supplies its value, so mentioning a
  key again replaces that entry wholesale. A replacement inherits the
  replaced entry's slot: its own imports are pulled into the
  composition, but they land later, guaranteeing reachability rather
  than precedence.
- **Cycles terminate.** The walk skips a key that is already on its
  own path. Members of a cycle get no ordering guarantee relative to
  each other; everything else is unaffected.
- **Keyless entries are a local tail.** An entry with `key = null`
  cannot be imported. Keyless entries apply after the entire keyed
  world, in list order, and stack when listed repeatedly. They are
  the consumer's private patch layer: having no key, they can never
  be replaced by another entry.
- **Application is a classic overlay fold.** `prev` is everything
  accumulated so far; references through `final` see the finished
  fixpoint. One law follows from the fixpoint itself: an overlay's
  output attribute *names* must not depend on `final`.
- `compose` also returns `meta` (key order, winning entries, tail
  length) so tooling can inspect and lint a composition; the engine
  itself never warns.

## Ecosystem-source resolution

`resolve` implements layered lookup for handing ecosystem sources
(such as a nixpkgs lib directory) to higher layers:

```nix
core.resolve {
  name = "nixpkgs-lib";
  explicit = null;        # highest priority when non-null
  defaults = { };         # the client repository's declared defaults
  inputs = { };           # matched by exact name only
}
```

Priority is explicit argument, then declared default, then an input
with exactly the declared name. A full miss returns `null`; `resolve`
never throws and never formats an error message. Interpreting a miss
is deliberately left to the calling layer.

## The library lifecycle

`mkLib` builds a composed library from a base library plus registered
overlays and modules, and injects the `caisson-core` namespace
(machinery, module registry, manifest) into the result:

```nix
core.mkLib {
  inputs = inputs;        # the composing flake's inputs, closed over
                          # by registered overlays and modules
  baseLib = baseLib;      # the base library, as a plain argument;
                          # nothing is looked up by input name
  modules = composedLib: { };         # class-keyed local registrations
  libOverlays = mkLibOverlay: { };    # named overlay registrations
  libOverlayImports = builtins.attrValues;  # selection for this library
  ecosystems = { };                   # declared ecosystem sources, by
                                      # exact name; captured into the
                                      # manifest, interpreted by
                                      # higher layers
}
```

The composed library carries, under `caisson-core`: `mkLib` (with
`baseLib` defaulting to this composition's base), `mkLibOverlay`,
`mkModule` (class-parameterized), the class-keyed `modules` registry,
the `manifest` (the capture of what `mkLib` consumed: `inputs`,
`modules`, `libOverlays`, `ecosystems`), plus `compose`, `resolve`, `importApply`,
`callConsumerFlake`, and `partitionExtraInputs`. Overlays contribute
modules through their closure (`mkModule`, `contributeModules`); the
composing flake's local registrations apply last and win over
same-named contributions. `mkCoreOverlay` exposes the same namespace
injection as a built overlay for compositions assembled with
`compose` directly. The manifest carries no checks here: producers
validate their own manifests, and consuming integrations type-check
on the export side.

## The kernel

Two self-contained companions ship alongside the engine:

- `callFlake { src, inputs, sourceInfo ? { } }` applies a flake's
  outputs function to explicitly provided, already-wired inputs. No
  lock handling and no fetching; every input is a constructed flake
  or a plain source path.
- `partitionExtraInputs <dir>` loads a lockfile'd subflake directory
  and returns its inputs, safely under read-only evaluation (via the
  patched copy of flake-compat in [vendor/](vendor/flake-compat)).

Both keep the builtins-only rule; the vendored flake-compat carries
its own license and provenance header.

## Tests

The test suite is hermetic pure evaluation:

```sh
nix eval -f tests summary
```

## Status

Pre-release. The contract described above is intended to freeze;
until the first release it may still change.

## License

MIT. See [LICENSE](LICENSE).

caisson-core is an independent project, not affiliated with or
endorsed by the NixOS Foundation. Nix and NixOS are trademarks of the
NixOS Foundation.
