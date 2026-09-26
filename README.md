# caisson-core

caisson-core composes library overlays: identity,
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
  length) so tooling can inspect and lint a composition; `compose`
  itself does not warn, because linting belongs to that tooling.

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
can never throw or format an error message, because interpreting a
miss is deliberately the calling layer's job.

## The library lifecycle

`mkLib` builds a composed library from registered overlays and
modules over the empty seed, and injects the `caisson-core` namespace
(machinery, module registry, manifest) into the result:

```nix
core.mkLib {
  inputs = inputs;        # the composing flake's inputs, closed over
                          # by registered overlays and modules
  defaultEcosystemSrc = { nixpkgs = inputs.nixpkgs; };
                          # the tree's default source per ecosystem, by
                          # exact name; `nixpkgs` supplies the nixpkgs-lib
                          # part unless `nixpkgs-lib` names its own source
  modules = composedLib: { };         # class-keyed local registrations
  configs = composedLib: { };         # class-keyed configurations
                                      # (configs/<class>/<name>)
  libOverlays = mkLibOverlay: { };    # named overlay registrations
  libOverlayImports = builtins.attrValues;  # selection for this library
  projects = { };                     # consumed upstream contributions,
                                      # by project name
  systems = [ "x86_64-linux" ];       # the platforms the tree builds on;
                                      # null when absent
  namespace = "my-project";           # the namespace this composition
                                      # contributes to the composed library;
                                      # null when absent
}
```

A tree laid out as `modules/<class>/<name>/default.nix`,
`configs/<class>/<name>/default.nix` and
`lib-overlays/<name>/default.nix` derives the three registrations
from its directories: `modules = core.mkModules ./modules;`,
`configs = core.mkModules ./configs;` and
`libOverlays = core.mkLibOverlays ./lib-overlays;`. The first level of a
modules directory is the class, whatever its name, and each entry
registers through the class index of the composed library,
`caisson-core.classes.<class>`: the `mkModule` of the integration that
declares the class. An integration declares the class it owns from
its overlay (`contributeClasses prev { nixos = { integration =
"nixos"; mkModule = final.caisson-core.mkModule "nixos"; }; }`), a
declaration composed later replaces it, which is how an integration
wrapping another takes over the class, and caisson-core declares the
class-free `generic` class itself. A directory for a class no
composed integration declares is an error. `mkLibOverlays` applies
`mkLibOverlay` to each entry. An entry is a directory holding a
`default.nix`, a symlink to one included; anything else in a
directory being read is an error, so a stray file cannot silently
vanish from a registry. A tree with another layout writes the
registrations by hand.

Nothing is composed over. nixpkgs' library arrives as the published
`nixpkgs-lib` entry, which imports the `lib` directory of the source
supplying that part (`defaultEcosystemSrc.nixpkgs-lib`, else
`.nixpkgs`, else an input named exactly so) as that source fixes it;
a polyfill composed later overrides a name for readers of the
composed library, not for upstream's own internal references, since
nixpkgs' `lib/default.nix` exposes no way to re-tie its fixpoint. An
overlay that needs upstream's functions imports the
entry from its closure (`{ entries, ... }: { imports = [ entries.nixpkgs-lib ]; ... }`);
a composition that declares no source fails only where that entry is
composed, with a message naming the declaration. The core entry
(`caisson-core`) and the `nixpkgs-lib` entry sit in the registry under
those names like any registration, so a same-name registration
replaces either.

The composed library carries, under `caisson-core`: `mkLib`,
`mkLibOverlay`, `mkModule` (class-parameterized), `mkModules`,
`mkLibOverlays`, `mkNixpkgsLibEntry`, the class-keyed `modules`
registry, the class index `classes`, the three manifest slots
(`libManifest`, `pkgsManifest`, `evalManifest`), plus `compose`,
`resolve`, `importApply`, `callConsumerFlake`, and
`partitionExtraInputs`. A registered overlay file takes the closure
attrset
`{ closure-inputs, closure-lib, mkLibOverlay, mkModule, contributeModules, contributeClasses, entries, ... }`
as its first arg list and a registered module
`{ closure-inputs, closure-lib, mkModule, ... }`; `closure-lib` is the
composed library of the composition that registered the file, bound
lazily, so an overlay's functions and a module reach that
composition's registry under `caisson-core.modules.<class>` wherever
they are later composed or evaluated. Overlays contribute modules
through their closure (`mkModule`, `contributeModules`); the
composing flake's local registrations apply last and win over
same-named contributions.

caisson-core is its own composition. `lib/default.nix` holds the one
primitive, `compose`, and composes the overlays under
`lib-overlays/<name>/default.nix` (`compose`, `resolve`, `kernel`,
`lifecycle`, `readers`) over the empty seed into the `caisson-core`
namespace; `mkLib` composes the same entries into every consumer's
library, keyed `caisson-core/<name>`, so `import caisson-core` and
`caisson-core` inside a composed library are one definition and each
part is a registered entry a same-key entry replaces. `coreEntries
{ inputs, entries }` returns those entries for a composition assembled
with `compose` directly.

A `projects` value is an attrset with `libOverlays` and class-keyed
`modules` dictionaries, the outputs a flake built on this machinery
already publishes. Its entries join the registered dictionaries under
`<project>/<name>`, so the existing selections keep per-item choice
and a local registration wins a name collision.

The manifest is the composition's self-description, recorded at
`caisson-core.libManifest`: `inputs`, `defaultEcosystemSrc`,
`systems`, `namespace`, the raw `projects` capture, the registered
`libOverlays` and `modules` dictionaries (project entries prefixed,
locals winning), and the `configs` registration, which also comes back
as `caisson-core.configs`. `namespace` is the name the composition
holds for itself, the namespace its overlays contribute to the
composed library; a layer above gives a configuration no parent
declares that name, since a name is otherwise the attribute a parent
declares a child under. It
is not passed anywhere; readers pull it back out of the composed
library. There is a slot per evaluation phase: `libManifest` is
filled here, and `pkgsManifest` and `evalManifest` are present and
null, for the layers that build package sets and module evaluations
to fill on the libraries they hand out. Higher
layers project a flake's `libOverlays` and `modules` outputs from it,
and the `projects` argument consumes those projections one level
down, which is how dictionaries populate across flakes. The manifest
carries no checks here: producers validate their own manifests, and
consuming integrations type-check on the export side.

## The kernel

Two self-contained companions ship alongside `compose`:

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
until the first release it may still change. The
[caisson framework](https://github.com/nix-caisson/caisson) builds
on this repository, and
[caisson-compat](https://github.com/nix-caisson/caisson-compat)
tests the family against pinned upstreams.

## License

MIT. See [LICENSE](LICENSE).

Despite the org name, caisson-core is an independent project, not
affiliated with or endorsed by the NixOS Foundation. Nix and NixOS
are trademarks of the NixOS Foundation.
