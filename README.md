# caisson-core

caisson-core composes library overlays: identity,
replacement, and deterministic order, implemented over plain Nix
builtins.

caisson-core has **zero flake inputs** and its library code references
nothing but `builtins`. It is the foundation layer of the caisson
family; it is useful by itself to anyone who wants to compose an
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
  replaced entry's position: its imports are pulled into the
  composition, but they land later, guaranteeing reachability rather
  than precedence.
- **Cycles terminate.** The walk skips a key that is already on its
  path. Members of a cycle get no ordering guarantee relative to
  each other; everything else is unaffected.
- **Keyless entries are a local tail.** An entry with `key = null`
  cannot be imported. Keyless entries apply after the entire keyed
  world, in list order, and stack when listed repeatedly. They are
  the consumer's private patch layer: having no key, they can never
  be replaced by another entry.
- **Application is a classic overlay fold.** `prev` is everything
  accumulated so far; references through `final` see the finished
  fixpoint. A law follows from the fixpoint itself: an overlay's
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
  sources = { };          # the pinned sources, matched by exact name only
}
```

Priority is explicit argument, then declared default, then the pinned
source with exactly the declared name. A full miss returns `null`; `resolve`
can never throw or format an error message, because interpreting a
miss is deliberately the calling layer's job.

## The library lifecycle

`mkLib` builds a composed library from registered overlays and
modules over the empty seed, and injects the `caisson-core` namespace
(machinery, module registry, manifest) into the result:

```nix
core.mkLib {
  # The tree's pinned sources, closed over by registered overlays and
  # modules as `closure-inputs`, and the tree's root, as a pin reader
  # returns them (see Pin readers). Only `sources` is required.
  inherit (core.pins.flake inputs) sources root;
  defaultEcosystemSrc = { nixpkgs = inputs.nixpkgs; };
                          # the tree's default source per ecosystem, by
                          # exact name; `nixpkgs` supplies the nixpkgs-lib
                          # part unless `nixpkgs-lib` is declared separately
  modules = lib: { };                 # class-keyed local registrations,
                                      # given the bootstrap lib
  configs = lib: { };                 # class-keyed configurations
                                      # (configs/<class>/<name>), given
                                      # the bootstrap lib
  libOverlays = lib: { };             # named overlay registrations, given
                                      # the core lib; an entry is made with
                                      # lib.caisson-core.mkLibOverlay
  libOverlayImports = lib: [ lib.caisson-core.nixpkgs-lib.overlays.my-overlay ];
                                      # selection for this library, given
                                      # the core lib; defaults to every
                                      # project and local registration
  extraLibOverlayImports = lib: [ ];  # entries added to that selection
  pkgOverlays = lib: { };             # named package overlay registrations,
                                      # given the bootstrap lib; an entry is
                                      # made with lib.caisson-core.mkPkgOverlay
  pkgSets = lib: { };                 # package configs by config name, each
                                      # an integration's mkConfiguration
                                      # call, given the registered lib
  projects = { };                     # consumed upstream contributions,
                                      # by project name
  systems = [ "x86_64-linux" ];       # the platforms the tree builds on;
                                      # null when absent
  name = "my-project";                # the project's name, also the
                                      # namespace it contributes to the
                                      # composed library; null when absent
}
```

The signature is the pattern of `mkLib`, with no `...`: a missing or
unexpected argument is Nix's error at the call site, naming
`mkLib` and pointing at the pattern, whose comments say what each
argument is.

The library is built in stages, each a new fixpoint over the
empty seed with a manifest in `caisson-core.libManifest`, and
each there because some argument is a function of it. The core lib
holds caisson-core's entries and nothing else, with the lib
overlay registry grafted onto its manifest; it is the lib
`libOverlays` and `libOverlayImports` receive, so a registration
makes its entries with `lib.caisson-core.mkLibOverlay` and a selection
refers to entries as
`lib.caisson-core.nixpkgs-lib.overlays.<name>`. `libOverlayImports`
replaces the default selection, every registered overlay that is not a
published entry, and `extraLibOverlayImports`, of the same form, adds
to the selection, whichever it is. The bootstrap lib
adds the selection, the `nixpkgs-lib` entry and every integration
among it; it is the lib `modules`, `configs` and `pkgOverlays`
receive, and its
manifest lacks `modules`, `moduleProjects`, `configs`, `pkgOverlays`
and `pkgSets`. The registered lib is the same entries with those
registrations grafted on; it is the lib `pkgSets` receives, since a
package config selects from the registered modules and package
overlays, and its manifest lacks `pkgSets`. The full lib adds
`pkgSets`, and it is the lib `mkLib` returns. The core, bootstrap and
registered manifests have `childless = true`. A registration made
at an earlier stage still closes over the full lib: the
constructors those libs hold (`mkModule` and every class-bound
`mkModule` made from it, `mkLibOverlay`, `mkPkgOverlay`) give
`closure-lib` the full lib, whose `caisson-core.modules` is the
registry the entry joins. A same-key registration replaces one of
caisson-core's entries from the bootstrap stage on; the core lib keeps
the original.

A tree laid out as `modules/<class>/<name>/default.nix`,
`configs/<class>/<name>/default.nix`,
`lib-overlays/<name>/default.nix` and
`pkg-overlays/<name>/default.nix` derives the registrations
from its directories, with the readers of the lib each registry
function is handed:
`modules = lib: lib.caisson-core.mkModules ./modules;`,
`configs = lib: lib.caisson-core.mkModules ./configs;`,
`libOverlays = lib: lib.caisson-core.mkLibOverlays ./lib-overlays;` and
`pkgOverlays = lib: lib.caisson-core.mkPkgOverlays ./pkg-overlays;`.
A reader belongs to the lib it is read from, so a composition that
registers another `caisson-core/readers` entry reads its directories
with that entry. The first level of a
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
`mkLibOverlay` to each entry, and `mkPkgOverlays` `mkPkgOverlay`. An entry is a directory holding a
`default.nix`, a symlink to such a directory included; anything else in a
directory being read is an error, so a stray file cannot silently
vanish from a registry. A tree with another layout writes the
registrations by hand.

Nothing is composed over. nixpkgs' library arrives as the published
`nixpkgs-lib` entry, which imports the `lib` directory of the source
supplying that part (`defaultEcosystemSrc.nixpkgs-lib`, else
`.nixpkgs`, else a pinned source named exactly so) as that source fixes it;
a polyfill composed later overrides a name for readers of the
composed library, not for upstream's internal references, since
nixpkgs' `lib/default.nix` exposes no way to re-tie its fixpoint. An
overlay that needs upstream's functions imports the
entry from its closure (`{ entries, ... }: { imports = [ entries.nixpkgs-lib ]; ... }`);
a composition that declares no source fails only where that entry is
composed, with a message naming the declaration. The core entry
(`caisson-core`) and the `nixpkgs-lib` entry sit in the registry under
those names like any registration, so a same-name registration
replaces either.

The composed library carries, under `caisson-core`: `mkLib`,
`mkLibOverlay`, `mkPkgOverlay`, `mkModule` (class-parameterized),
`mkModules`, `mkLibOverlays`, `mkPkgOverlays`, `pkgOverlaysFor`,
`mkNixpkgsLibEntry`, the class-keyed `modules`
registry, the class index `classes`, the phase manifests
(`libManifest`, `pkgsManifest`, `evalManifest`), `manifestOf`,
`definers`, `finalizeChild`, `mkConfiguration`, `finalizeTop`, `elide`,
the lib
overlay registry view
`nixpkgs-lib.overlays` (the manifest's `libOverlays`, which a
`libOverlayImports` selection refers into),
plus `compose`,
`resolve`, `importApply`, `callConsumerFlake`, and the pin readers
`pins`. A registered overlay file takes the closure
attrset
`{ closure-inputs, closure-lib, mkLibOverlay, mkModule, contributeModules, contributeClasses, entries, ... }`
as its first arg list and a registered module
`{ closure-inputs, closure-lib, mkModule, ... }`; `closure-inputs` is
the composition's pinned sources, and `closure-lib` is the
composed library of the composition that registered the file, bound
lazily, so an overlay's functions and a module reach that
composition's registry under `caisson-core.modules.<class>` wherever
they are later composed or evaluated. Overlays contribute modules
through their closure (`mkModule`, `contributeModules`); the
composing flake's local registrations apply last and win over
same-named contributions.

caisson-core composes itself. `lib/default.nix` holds the
primitive, `compose`, and composes the overlays under
`lib-overlays/<name>/default.nix` (`compose`, `resolve`, `kernel`,
`lifecycle`, `readers`, `pins`) over the empty seed into the `caisson-core`
namespace; `mkLib` composes the same entries into every consumer's
library, keyed `caisson-core/<name>`, so `import caisson-core` and
`caisson-core` inside a composed library are one definition and each
part is a registered entry a same-key entry replaces. `coreEntries
{ sources, entries }` returns those entries for a composition assembled
with `compose` directly.

A `projects` value is an attrset with `libOverlays`, class-keyed
`modules` and `pkgOverlays` dictionaries, the outputs a flake built on
this machinery publishes. Its entries join the registered dictionaries
under `<project>/<name>`, so the existing selections keep per-item
choice and a local registration wins a name collision. Each registry
records where an entry came from, so an export selector can keep the
entries the composition registered itself: a lib overlay entry carries
`project` (null for a local registration, the project's name for a
contributed entry, `caisson-core` for the entries caisson-core publishes
into every composition), and the manifest's `moduleProjects.<class>.<name>`
holds the same for modules, beside the module dictionary, since a
module value cannot carry a field without becoming a different module.

The package overlay registry holds package overlays in the lib
overlay entry's shape: a file handed to `mkPkgOverlay` takes the
closure `{ closure-inputs, closure-lib, mkPkgOverlay, ... }` and
returns `{ imports ? [ ], overlay }`, where `overlay` is a nixpkgs
overlay. Every registered entry carries its registry name as `key`,
the file it was read from as `origin` (null for an entry built from a
function), and `project`, null for a local registration and the
project's name for a contributed entry, so a selection of the local
entries alone is a filter on that field. An entry imports a sibling
from the registry of the composition that registered it,
`closure-lib.caisson-core.libManifest.pkgOverlays.<name>`. A
project's entries are rekeyed as they join: a key without a `/` is
one of the project's names and becomes `<project>/<key>`, imports
included, so an import still meets its sibling; a key with a `/`
names an entry the project took from another project and is kept, so
two projects importing the same entry import one entry. Nothing in
caisson-core applies the registry. `pkgOverlaysFor selection` turns a
list of entries into the list of nixpkgs overlays a package set
applies: each entry after the entries it imports, each key once where
it first occurs, and two entries with different origins under one key
refused. By convention the entries named `default` (`default`,
`<project>/default`) are the default selection, as for modules; the
layer that builds package sets applies that default.

The manifest is the composition's self-description, recorded at
`caisson-core.libManifest`: `sources` (a directory reader's pin files
stated relative to the root when the directory lies in the root's
tree, `pin.dir` kept otherwise), `root` (null for a composition that
is not a top), `defaultEcosystemSrc`, `systems`, `name`, the raw
`projects` capture, the registered
`libOverlays`, `modules` and `pkgOverlays` dictionaries (project
entries prefixed, locals winning), `moduleProjects`, the `configs` registration, which also comes back
as `caisson-core.configs`, and `pkgSets`, the package configs the
`pkgSets` function declared, each finalized. A configuration learns
its name and its parent from where it is declared, so an integration's
`mkConfiguration` returns a function `{ name, parent }: <manifest>`:
`finalizeChild { name; parent; } child` calls it with both, after
checking with `builtins.functionArgs` that its pattern names exactly
`name` and `parent`, and requires a manifest back. `mkLib` finalizes
each `pkgSets` entry with the name it is declared under and the
registered manifest as its parent, so anything else declared there is
refused where it is declared. The registered manifest lacks `pkgSets`, so the
full manifest lists the configs without containing itself, and
caisson-core interprets nothing in them beyond the manifest shape. `name` is the project's name as declared
on `mkLib`, the name the composition holds for itself and the
namespace its overlays contribute to the composed library, and it is
absent when none is declared; a layer above gives a configuration no parent declares that
name, since a name is otherwise the attribute a parent declares a
child under. It is not passed anywhere; readers pull it back out of
the composed library. `type` is `"lib"`. `entries` lists the
selection in composition order, caisson-core's forced entries first,
each as `{ key, opaque }`; an entry is opaque when its key names no
registry entry (an overlay imported by value rather than
registered), and a keyless entry gets a synthesized `keyless/<n>`
key. The lib `mkLib` returns is the full lib of a root declaration,
so `childless` is false, `parent` is null, and `ancestors`, `inputs`,
`nearest` and `children` are empty. `history` lists the events
recorded on the way to the lib, in stage order, and the history of
each stage begins with the history of the stage before it. The core
stage records one `layer` event per caisson-core entry, then the lib
overlay registrations. The bootstrap stage adds one `layer` event per
entry it composes that the core stage did not, in composition order:
the selection, and a registration replacing a caisson-core entry,
which so comes after the entry it replaces. The registered stage adds
the `modules`, `configs` and `pkgOverlays` registrations, and the full
stage the `pkgSets` registrations.
Each event has `manifest` (the name path, empty for the root lib),
`type`, `operation` (`registry` or `layer`), `key`, `index` (its
position within its operation) and `origin` (`project`, and `file`
where the entry was built from a file; a lib overlay built from a file
records it as `origin`). A layer event also carries, lazily, the
sides of its overlay call `final: prev: result`, as the stage that
recorded it composed them: `result`, the attrset its overlay
returned, and `prev`, the accumulation it received.
`definers manifest [ "my-project" "helper" ]` reads them: the layers
that define that path in order, the winner last, each with its value
after the layer and its binding position when that lies in the
layer's file. A layer returning `prev.x // { ... }` carries the names
under `x` without defining them. A lib carries a manifest per evaluation phase: `libManifest` is
filled in here, and `pkgsManifest` and `evalManifest` are present and
null, for the layers that build package sets and module evaluations
to fill in on the libraries they hand out. Every stage `mkLib` builds
carries `caisson-core.withManifests { pkgsManifest = manifest; }`,
which rebuilds that stage from its declaration with the given phase
manifests filled in: the same entries and `libManifest`, composed as a
new fixpoint, so everything that reads a phase manifest through the
fixpoint sees it. It is how the nixpkgs integration hands out
`pkgs.lib`, the lib the package config was declared under (the
registered lib, for a `pkgSets` entry) with `pkgsManifest` filled in.
Only `pkgsManifest` and
`evalManifest` are accepted, each a manifest or null, and a rebuilt
lib carries `withManifests` too, keeping what is already filled in.

`caisson-core.mkConfiguration { type; evaluate; record ? { };
perSystem ? false; }` returns
the configuration of a module evaluation, the function of
`{ name, parent }` above. Nothing is evaluated until the manifest that
function returns has its `value`, `outputs` or `children` read.
`type` is the name of the integration.
`evaluate` performs the evaluator's call: it takes `{ lib, manifest }`,
the lib the evaluation runs on and the manifest being built, and
returns `value`, `outputs` and `children`, the finalized configurations
declared beneath by integration and then name. `record` is plain data
the integration adds to the manifest, and it may not name a field
`mkConfiguration` writes. The evaluation has a childless view and a
full view, each a manifest whose lib is the declaring lib rebuilt
with that manifest as `evalManifest`. The childless view
(`childless = true`, no `children`) is the evaluation without the
configurations declared beneath it. The
full view is the manifest returned; it carries the childless manifest as
`childlessManifest`, and an integration finalizes each child against
that (`finalizeChild { inherit name; parent =
manifest.childlessManifest; }`), so a child's `parent` is the
childless manifest of the configuration that declares it. The
childless evaluation runs only when a child, or a reader of
`childlessManifest`, reads its value, so a configuration with no
children is evaluated once. Both views carry `type`, `name`, `parent`,
`ancestors` (the parent's list with the parent appended), `nearest`
(the parent's attrset with the parent under its integration, a lib
excepted), `inputs` (the lib's manifest, and on the full view the
childless manifest and the children) and the parent's `sources`,
`root`, `systems`, `projects`, `defaultEcosystemSrc`, `pkgSets` and
registries. A manifest also inherits `selectPkgs`, the selection of
the package set a configuration runs on, where a configuration above
it recorded one: an integration records the selection a configuration
makes (`record.selectPkgs`), and it is in force for everything beneath
that configuration until a configuration beneath records another.
`caisson-core.finalizeTop configuration` finalizes the
configuration a top ends with: its name is the name the composition
declares on `mkLib`, absent when it declares none, and its parent is
the lib's manifest.

An integration that evaluates a configuration at a system passes
`perSystem = true`. A declared configuration is then an evaluation for
every system in force where it is declared, and the configuration
returns those evaluations by system: as many as there are systems in
force, also when that is a single system, and none when no system is
in force; nothing is refused. In the tree the system sits above the
name. Each evaluation is a manifest as described above, with the
childless and full views, under the name it is declared by, carrying
its system as `system`; its parent is the system, a manifest of type
`system` named by the system, beneath the parent that declares the
configuration. The parent's full manifest holds each system under
`children.system`, with the evaluations declared at it by integration
and then name, beside the configurations evaluated once for every
system, which stay under `children.<integration>`. An evaluation sees
the system above it without what is declared under it. The systems in
force carry on beneath an evaluation, so a configuration declared
beneath it has a system above it in turn. `finalizeChild` accepts
either result, a manifest or the evaluations by system.

An evaluation registers modules for the configurations beneath it.
`evaluate` may return `forChildren` beside `value`, `outputs` and
`children`: `modules`, by class and then name, and
`defaultModuleImports`, by class a list of selections, each a function
of a lib returning modules. They are read from the childless view and
recorded on the manifest as `forChildren`. A configuration beneath
inherits the registry and the selections of its parent extended by
them: its manifest holds the registry it sees as `modules`, where a
registration under a name already there replaces the entry, and the
selections added above it as `defaultModuleImports`, those from the
top first. The lib an evaluation runs on shows that registry as
`caisson-core.modules`. Every level on the way down extends both in
turn, so a registration reaches every configuration beneath the level
that made it, at any depth, and it reaches nothing at that level or
beside it.

`caisson-core.elide paths` gives, for each of a set of things in a
tree, the segments needed to tell it apart from the others. A path is
the list of `{ type, name }` segments from the top down to the thing,
ending in the name of the thing; a system is a segment of type
`system`. The result has, for each path in order, the segments kept,
as strings. The rule keeps the last segment of every path, and beyond
it only the segments where paths that end in the same name fork: among
those paths it drops the prefix they share, keeps the segment at which
they first differ, and does the same within each branch. So a name
that is alone stays bare, whatever sits above it, and names that
collide gain what tells them apart: `hostname1` at a single system
stays `hostname1`, and `hostname2` at `x86_64-linux` and
`aarch64-linux` keeps the system. A segment is kept as its name, or as
`type/name` where the branches of that fork hold the same name under
several types. How the kept segments are written out as a name, and a
clash between equal paths, are for whoever publishes them.

Every manifest carries
`_type = "caisson-manifest"`, and `manifestOf` finds it in whatever
a file returns: a manifest, an attrset carrying `caisson.manifest`,
an evaluated configuration carrying `config.caisson.manifest`, or a
library (or a package set, through `pkgs.lib`) carrying the phase
manifests, where the last manifest filled in is the manifest. It
returns null when the value carries none. Higher
layers project a flake's `libOverlays` and `modules` outputs from it,
and the `projects` argument consumes those projections one level
down, which is how dictionaries populate across flakes. The manifest
carries no checks here: producers validate their manifests, and
consuming integrations type-check on the export side.

## The kernel

`callFlake { src, inputs, sourceInfo ? { } }` ships alongside
`compose`: it applies a flake's outputs function to explicitly
provided, already-wired inputs. No lock handling and no fetching;
every input is a constructed flake or a plain source path.
`callConsumerFlake` builds on it. The inputs of a lockfile'd subflake,
what a flake-parts partition takes as `extraInputs`, are what
`pins.flake-compat` reads (below).

## Pin readers

A tree is built from pinned sources. `pins` holds a reader per pin
system, each reading that system's files into `sources`: every pinned
tree, as the pin system hands it over (a flake input keeps its
outputs), plus `pin`, the record of how it is pinned (`system`, the
pin `files`, `url`, `rev`, `narHash`, `lastModified`).

```nix
# In a flake's outputs: the inputs Nix resolved, with any
# --override-input in force, and the root from `self`.
inherit (caisson-core.pins.flake inputs) sources root;

# A flake.nix and flake.lock pair Nix's flake evaluator does not see,
# such as a tests/dependencies directory, resolved the way
# flake-compat does: a flake input comes with its outputs. Nothing
# overrides it and it has no root. A flake-parts partition takes these
# sources as its `extraInputs`.
inherit (caisson-core.pins.flake-compat ./tests/dependencies) sources;

# npins (sources.json format 8).
inherit (caisson-core.pins.npins ./npins) sources;
```

`root` names the tree being built: `{ outPath; dirty; rev; shortRev;
dirtyRev; dirtyShortRev; lastModified; lastModifiedDate; narHash; }`,
the source-info fields a flake's `self` carries, each null where the
reader has none. The names are fixed and the values lazy, since
inside a flake's `outputs` asking which attributes `self` has forces
the outputs being computed. A flake reads it from `self`; a flakeless
top in a git working tree reads it with `caisson-core.pins.gitRoot ./.`
(under an impure evaluation, since the working tree is not locked),
which gives the revision of a clean tree and marks a dirty tree.

A flake input declared as a `follows` is the tree it lands on, with
`pin.follows` naming the input path it follows. When an
`--override-input` replaced a flake input, `pin.overridden` is true
and `pin.url` still describes the lock.

## Tests

The test suite is hermetic pure evaluation:

```sh
nix eval -f tests summary
```

## Status

Pre-release. The contract described above is intended to freeze;
until the first release it may still change. The
[caisson framework](https://github.com/nix-caisson/caisson) builds
on this repository, and its pinned-world check tests the family
against pinned upstreams.

## License

MIT. See [LICENSE](LICENSE).

Despite the org name, caisson-core is an independent project, not
affiliated with or endorsed by the NixOS Foundation. Nix and NixOS
are trademarks of the NixOS Foundation.
