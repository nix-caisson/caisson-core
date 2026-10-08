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
(the tree a library or an evaluator is loaded from) to higher layers:

```nix
core.resolve {
  name = "some-ecosystem";
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
  defaultEcosystemSrc = { some-ecosystem = inputs.some-ecosystem; };
                          # the tree's default source per ecosystem, by
                          # exact name; read back with `ecosystemSrc`
  modules = lib: { };                 # class-keyed local registrations,
                                      # given the bootstrap lib
  configs = lib: { };                 # class-keyed configurations
                                      # (configs/<class>/<name>), given
                                      # the bootstrap lib
  libOverlays = lib: { };             # named overlay registrations, given
                                      # the core lib; an entry is made with
                                      # lib.caisson-core.mkLibOverlay
  libOverlayImports = lib: [ lib.caisson-core.libOverlays.my-overlay ];
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

The rest of this section is reference, one topic per heading:

- how the library is built: [Stages](#stages),
  [Selecting lib overlays](#selecting-lib-overlays),
  [Registering from directories](#registering-from-directories),
  [Module classes](#module-classes),
  [Libraries loaded from a source](#libraries-loaded-from-a-source);
- what it holds: [What the composed library carries](#what-the-composed-library-carries),
  [What a registered file receives](#what-a-registered-file-receives),
  [caisson-core composes itself](#caisson-core-composes-itself),
  [Projects](#projects), [Package overlays](#package-overlays);
- what it records: [The manifest](#the-manifest), [History](#history),
  [Phase manifests](#phase-manifests);
- the tree of configurations: [Configurations](#configurations),
  [Evaluating a configuration with and without its children](#evaluating-a-configuration-with-and-without-its-children),
  [Configurations evaluated per system](#configurations-evaluated-per-system),
  [What an evaluation gives the configurations inside it](#what-an-evaluation-gives-the-configurations-inside-it),
  [Telling names apart](#telling-names-apart-elide),
  [Finding a manifest](#finding-a-manifest-manifestof).

### Stages

The library is built in stages. Each is a new fixpoint over the
empty seed with a manifest in `caisson-core.libManifest`, and each
exists because some argument of `mkLib` is a function of it.

| Stage | What it holds | Arguments that receive it | Its manifest lacks |
| --- | --- | --- | --- |
| core | caisson-core's entries, with the lib overlay registry on its manifest | `libOverlays`, `libOverlayImports`, `extraLibOverlayImports` | everything below |
| bootstrap | the core lib plus the selection, which is where the integrations are | `modules`, `configs`, `pkgOverlays` | `modules`, `moduleProjects`, `configs`, `pkgOverlays`, `pkgSets` |
| registered | the same entries, with those registrations on the manifest | `pkgSets` | `pkgSets` |
| full | the registered lib plus `pkgSets` | none: `mkLib` returns it | nothing |

- `pkgSets` receives the registered lib because a package config
  selects from the registered modules and package overlays.
- The core, bootstrap and registered manifests have
  `childless = true`.
- A registration made at an earlier stage still closes over the full
  lib. The constructors those libs hold (`mkModule` and every
  class-bound `mkModule` made from it, `mkLibOverlay`, `mkPkgOverlay`)
  give `closure-lib` the full lib, whose `caisson-core.modules` is the
  registry the entry joins.
- A same-key registration replaces one of caisson-core's entries from
  the bootstrap stage on. The core lib keeps the original.

### Selecting lib overlays

A `libOverlays` registration makes its entries with
`lib.caisson-core.mkLibOverlay`, and a selection refers to entries as
`lib.caisson-core.libOverlays.<name>`.

- The default selection is every registered overlay that is not a
  published entry.
- `libOverlayImports` replaces the default selection.
- `extraLibOverlayImports`, of the same form, adds to the selection,
  whichever it is.

### Registering from directories

A tree with this layout derives its registrations from its
directories, using the readers of the lib each registry function is
handed:

| Directory | Registration |
| --- | --- |
| `modules/<class>/<name>/default.nix` | `modules = lib: lib.caisson-core.mkModules ./modules;` |
| `configs/<class>/<name>/default.nix` | `configs = lib: lib.caisson-core.mkModules ./configs;` |
| `lib-overlays/<name>/default.nix` | `libOverlays = lib: lib.caisson-core.mkLibOverlays ./lib-overlays;` |
| `pkg-overlays/<name>/default.nix` | `pkgOverlays = lib: lib.caisson-core.mkPkgOverlays ./pkg-overlays;` |

- A reader belongs to the lib it is read from, so a composition that
  registers another `caisson-core/readers` entry reads its directories
  with that entry.
- An entry is a directory holding a `default.nix`, or a symlink to
  such a directory. Anything else in a directory being read is an
  error, so a stray file cannot silently vanish from a registry.
- `mkLibOverlays` applies `mkLibOverlay` to each entry, and
  `mkPkgOverlays` applies `mkPkgOverlay`.
- A tree with another layout writes the registrations by hand.

### Module classes

The first level of a modules directory is the class, whatever its
name. Each entry registers through the class index of the composed
library, `caisson-core.classes.<class>`, which holds the `mkModule` of
the integration that declares the class.

- An integration declares the class it owns from its overlay:
  `contributeClasses prev { nixos = { integration = "nixos"; mkModule = final.caisson-core.mkModule "nixos"; }; }`.
- A declaration composed later replaces an earlier one, which is how
  an integration wrapping another takes over the class.
- caisson-core declares the class-free `generic` class.
- A directory for a class no composed integration declares is an
  error.

### Libraries loaded from a source

Nothing is composed over, and caisson-core ships no entry for any
ecosystem. A library that exists outside the tree arrives as an
entry that some project registers. Such an
entry loads the library from a source and merges it in, so the names
it adds come from the source.

- It reads the source from `prev.caisson-core.ecosystemSrc "<name>"`
  (see below), and so loads the library of the composition it is
  composed into, whichever tree registered it.
- An overlay that calls the functions of that library imports the
  entry by key, so composing the overlay composes the entry.
- An entry imported under a key the composing tree registers is read
  from the registry of that tree. Registering under the key replaces
  the entry wherever it is composed.
- A composition that supplies no source fails only where the entry is
  composed.

The caisson framework supplies such an entry for the library its
integrations call.

### What the composed library carries

Under `caisson-core`:

| Group | Names |
| --- | --- |
| Composition | `mkLib`, `compose`, `resolve`, `importApply`, `callConsumerFlake` |
| Entry constructors | `mkLibOverlay`, `mkPkgOverlay`, `mkModule` (class-parameterized) |
| Directory readers | `mkModules`, `mkLibOverlays`, `mkPkgOverlays` |
| Registries | the class-keyed `modules`, the class index `classes`, `libOverlays` and `pkgOverlays` (views of the manifest fields of those names, each under the name of the `mkLib` argument that fills it; a `libOverlayImports` selection refers into the first and a package set selects from the second), `pkgOverlaysFor` |
| Manifests | `libManifest`, `pkgsManifest`, `evalManifest`, `manifestOf`, `definers` |
| Configurations | `mkConfiguration`, `finalizeChild`, `finalizeTop`, `elide` |
| Pins | `pins` |
| Sources | `ecosystemSrc` |
| Lists | `lists.unique`, `lists.zipListsWith`, `lists.init`, `lists.last` |
| Attribute sets | `attrsets.genAttrs`, `attrsets.filterAttrs` |
| Strings | `strings.hasInfix` |
| Functions | `functions.functionArgs`, `functions.setFunctionArgs` |

The last four rows are what code written on caisson-core needs and
`builtins` lacks, grouped as the library of nixpkgs groups the
functions of the same names. With them such code can be composed in a
library that holds no other library.

`ecosystemSrc <name>` is the source the composition supplies for an
ecosystem, by exact name: the `defaultEcosystemSrc.<name>` it
declares, else the source it pins under that name, else null. It is
fixed by the arguments of the `mkLib` call, so an overlay composed
after caisson-core's entries may read it from `prev` to decide what
it adds. An entry that a project contributes then gets the source of
the composition it is composed into.

### What a registered file receives

A registered file takes a closure attribute set as its first argument
list:

- an overlay file takes
  `{ closure-inputs, closure-lib, mkLibOverlay, mkModule, contributeModules, contributeClasses, ... }`;
- a module file takes `{ closure-inputs, closure-lib, mkModule, ... }`.

`closure-inputs` is the pinned sources of the composition.
`closure-lib` is the composed library of the composition that
registered the file, bound lazily. So the functions of an overlay,
and a module, reach the registry of that composition under
`caisson-core.modules.<class>` wherever they are later composed or
evaluated.

Overlays contribute modules through their closure (`mkModule`,
`contributeModules`). The local registrations of the composing flake
apply last and win over same-named contributions.

### caisson-core composes itself

`lib/default.nix` holds the primitive, `compose`, and composes the
overlays under `lib-overlays/<name>/default.nix` (`compose`,
`resolve`, `kernel`, `lifecycle`, `readers`, `pins`, `lists`,
`attrsets`, `strings`, `functions`) over the empty
seed into the `caisson-core` namespace.

`mkLib` composes the same entries into the library of every consumer,
keyed `caisson-core/<name>`. So `import caisson-core` and
`caisson-core` inside a composed library are one definition, and each
part is a registered entry that a same-key entry replaces.

`coreEntries { sources, defaultEcosystemSrc }` returns those entries for a
composition assembled with `compose` directly.

### Projects

A `projects` value is an attribute set with `libOverlays`,
class-keyed `modules` and `pkgOverlays` dictionaries: the outputs a
flake built on this machinery publishes. Its entries join the
registered dictionaries under `<project>/<name>`, so the existing
selections keep per-item choice and a local registration wins a name
collision.

Each registry records where an entry came from, so an export selector
can keep the entries the composition registered:

- A lib overlay entry carries `project`: null for a local
  registration, the name of the project for a contributed entry, and
  `caisson-core` for the entries caisson-core is made of.
- For modules the manifest holds the same under
  `moduleProjects.<class>.<name>`, beside the module dictionary,
  since a module value cannot carry a field without becoming a
  different module.

### Package overlays

The package overlay registry holds package overlays in the shape of a
lib overlay entry. A file handed to `mkPkgOverlay` takes the closure
`{ closure-inputs, closure-lib, mkPkgOverlay, ... }` and returns
`{ imports ? [ ], overlay }`, where `overlay` is an overlay of a package set (`final: prev:`).

Every registered entry carries:

| Field | Value |
| --- | --- |
| `key` | its registry name |
| `origin` | the file it was read from, null for an entry built from a function |
| `project` | null for a local registration, the name of the project for a contributed entry |

A selection of the local entries alone is a filter on `project`.

An entry imports a sibling from the registry of the composition that
registered it, `closure-lib.caisson-core.libManifest.pkgOverlays.<name>`.

The entries of a project are rekeyed as they join:

- A key without a `/` is a name of that project and becomes
  `<project>/<key>`, imports included, so an import still meets its
  sibling.
- A key with a `/` names an entry the project took from another
  project and is kept, so two projects importing the same entry import
  one entry.

Nothing in caisson-core applies the registry. `pkgOverlaysFor
selection` turns a list of entries into the list of overlays
a package set applies: each entry after the entries it imports, each
key once where it first occurs. Two entries with different origins
under one key are refused.

By convention the entries named `default` (`default`,
`<project>/default`) are the default selection, as for modules. The
layer that builds package sets applies that default.

### The manifest

The manifest is the self-description of the composition, recorded at
`caisson-core.libManifest`.

| Field | What it holds |
| --- | --- |
| `type` | `"lib"` |
| `name` | the name of the project as declared on `mkLib`; absent when none is declared |
| `sources` | the pinned sources. The pin files a directory reader read are stated relative to the root when the directory lies in the tree of the root, and `pin.dir` is kept otherwise |
| `root` | the tree being built; null for a composition that is not a top |
| `defaultEcosystemSrc`, `systems` | as declared on `mkLib` |
| `projects` | the `projects` argument as given |
| `libOverlays`, `modules`, `pkgOverlays` | the registered dictionaries, with project entries prefixed and local entries winning |
| `moduleProjects` | where each module came from |
| `configs` | the `configs` registration, also available as `caisson-core.configs` |
| `pkgSets` | the package configs the `pkgSets` function declared, each finalized |
| `entries` | the selection in composition order |
| `history` | the events recorded on the way to the lib |

The lib `mkLib` returns is the full lib of a root declaration, so
`childless` is false, `parent` is null, and `ancestors`, `inputs`,
`nearest` and `children` are empty.

**`name`** is the name the composition holds for itself, and the
namespace its overlays contribute to the composed library. It is not
passed anywhere: readers pull it back out of the composed library. A
layer above gives that name to a configuration no parent declares,
since a name is otherwise the attribute a parent declares a child
under.

**`entries`** lists each entry as `{ key, opaque }`, with the entries
caisson-core forces first. An entry is opaque when its key names no
registry entry, which is an overlay imported by value and not
registered. A keyless entry gets a synthesized `keyless/<n>` key.

**`pkgSets`** entries are configurations (see Configurations below).
`mkLib` finalizes each with the name it is declared under and the
registered manifest as its parent, so anything else declared there is
refused where it is declared. The registered manifest lacks `pkgSets`,
so the full manifest lists the configs without containing itself.
caisson-core interprets nothing in them beyond the manifest shape.

### History

`history` lists the events in stage order, and the history of each
stage begins with the history of the stage before it:

| Stage | Events it adds |
| --- | --- |
| core | one `layer` event per caisson-core entry, then the lib overlay registrations |
| bootstrap | one `layer` event per entry it composes that the core stage did not, in composition order: the selection, and a registration replacing a caisson-core entry, which so comes after the entry it replaces |
| registered | the `modules`, `configs` and `pkgOverlays` registrations |
| full | the `pkgSets` registrations |

Each event has:

- `manifest`, the name path, empty for the root lib;
- `type`;
- `operation`, `registry` or `layer`;
- `key`;
- `index`, its position within its operation;
- `origin`: `project`, and `file` where the entry was built from a
  file. A lib overlay built from a file records it as `origin`.

A layer event also carries, lazily, the sides of its overlay call
`final: prev: result`, as the stage that recorded it composed them:
`result`, the attribute set its overlay returned, and `prev`, the
accumulation it received.

`definers manifest [ "my-project" "helper" ]` reads them. It returns
the layers that define that path in order, the winner last, each with
its value after the layer and its binding position when that lies in
the file of the layer. A layer returning `prev.x // { ... }` carries
the names under `x` without defining them.

### Phase manifests

A lib carries a manifest per evaluation phase. `libManifest` is
filled in by `mkLib`. `pkgsManifest` and `evalManifest` are present
and null, for the layers that build package sets and module
evaluations to fill in on the libraries they hand out.

Every stage `mkLib` builds carries
`caisson-core.withManifests { pkgsManifest = manifest; }`, which
rebuilds that stage from its declaration with the given phase
manifests filled in: the same entries and `libManifest`, composed as
a new fixpoint, so everything that reads a phase manifest through the
fixpoint sees it.

- It is how a package set integration hands out `pkgs.lib`: the lib the
  package config was declared under (the registered lib, for a
  `pkgSets` entry) with `pkgsManifest` filled in.
- Only `pkgsManifest` and `evalManifest` are accepted, each a manifest
  or null.
- A rebuilt lib carries `withManifests` too, keeping what is already
  filled in.

### Configurations

A configuration is a module evaluation that sits in a tree: a NixOS
machine, a home, a flake. It learns its name and its parent from
where it is declared, so a configuration is a function
`{ name, parent }: <manifest>`.

`caisson-core.mkConfiguration { type; evaluate; record ? { }; perSystem ? false; }`
returns one:

| Argument | Meaning |
| --- | --- |
| `type` | the name of the integration |
| `evaluate` | the call of the evaluator. It takes `{ lib, manifest }`, the lib the evaluation runs on and the manifest being built, and returns `value`, `outputs` and `children`, the finalized configurations declared inside it by integration and then name |
| `record` | plain data the integration adds to the manifest. It may not name a field `mkConfiguration` writes |
| `perSystem` | whether the configuration is evaluated once per system (below) |

Nothing is evaluated until the manifest the function returns has its
`value`, `outputs` or `children` read.

A configuration is called by `finalizeChild` or `finalizeTop`:

- `finalizeChild { name; parent; } child` calls it with them, after
  checking with `builtins.functionArgs` that its pattern names exactly
  `name` and `parent`, and requires a manifest back, or the
  evaluations by system of a per-system configuration.
- `finalizeTop configuration` finalizes the configuration a top ends
  with. Its name is the name the composition declares on `mkLib`,
  absent when it declares none, and its parent is the manifest of the
  lib.

### Evaluating a configuration with and without its children

A configuration that declares children is evaluated with them and,
separately, without them. Each evaluation has its manifest, and each
runs on the declaring lib rebuilt with that manifest as
`evalManifest`.

- The **full evaluation** includes the configurations declared inside
  it. Its manifest is the one `mkConfiguration` returns, and it
  carries the other as `childlessManifest`.
- The **childless evaluation** (`childless = true`, no `children`)
  leaves them out. It is what the children are built against, so what
  a child reads of its parent does not depend on the children.

An integration finalizes each child against the childless manifest
(`finalizeChild { inherit name; parent = manifest.childlessManifest; }`),
so the `parent` of a child is the childless manifest of the
configuration that declares it. The childless evaluation runs only
when a child, or a reader of `childlessManifest`, reads its value, so
a configuration with no children is evaluated once.

Each of these manifests carries:

- `type`, `name` and `parent`;
- `ancestors`, the list of the parent with the parent appended;
- `nearest`, the attribute set of the parent with the parent under
  its integration, a lib excepted;
- `inputs`, the manifest of the lib, and on the full manifest the
  childless manifest and the children;
- from the parent: `sources`, `root`, `systems`, `projects`,
  `defaultEcosystemSrc`, `pkgSets` and the registries;
- `defaultPkgs`, where a configuration above recorded one (below).

### Configurations evaluated per system

An integration whose configurations are built for one system at a
time, such as NixOS, passes `perSystem = true`. Such a configuration
has one evaluation for each system it is evaluated for, and
finalizing it returns those evaluations by system. There are as many
as there are systems, also for a single system, and none when there
is no system. Nothing is refused.

In the tree the system sits above the name:

- Each evaluation is a manifest as described above, evaluated with
  and without its children, under the name it is declared by,
  carrying its system as `system`.
- Its parent is the system, a manifest of type `system` named by the
  system, inside the parent that declares the configuration.
- The full manifest of that parent holds each system under
  `children.system`, with the evaluations declared at it by
  integration and then name. Configurations evaluated once stay under
  `children.<integration>`.
- An evaluation sees the system above it without what is declared
  under it.

Which systems a per-system configuration is evaluated for depends on
where it is declared:

- Declared at the top, or inside a configuration evaluated once: the
  systems that configuration passes on, which start as the `systems`
  of `mkLib`.
- Declared inside another per-system configuration: the system of its
  parent, by default. A home declared inside a machine has, by
  default, one evaluation per evaluation of the machine, for the same
  system. The manifest of each machine evaluation holds that one
  system as `systems`.
- A parent changes what its children get by returning
  `forChildren.systems` (next section).

### What an evaluation gives the configurations inside it

`evaluate` may return `forChildren` beside `value`, `outputs` and
`children`. It is read from the childless evaluation and recorded on
the manifest as `forChildren`.

| Field | What it gives the configurations inside |
| --- | --- |
| `modules` | modules by class and then name, which join the registry those configurations see. A registration under a name already there replaces the entry |
| `defaultModuleImports` | by class, a list of selections, each a function of a lib returning modules, added to the default selection of that class, those from the top first |
| `defaultPkgs` | a selection of the package set for the configurations inside, in place of the selection the evaluation runs on. Null when it makes none |
| `systems` | the systems its per-system children are evaluated for. Null when it states none |

How they are inherited:

- The manifest of a configuration holds the registry it sees as
  `modules`, the selections added above it as `defaultModuleImports`,
  and the package set selection as `defaultPkgs`. The lib an
  evaluation runs on shows that registry as `caisson-core.modules`.
- Every level on the way down extends or replaces them in turn. So
  what a level gives is inherited by the configurations inside it,
  nested ones included, until a level between replaces it.
- The level that gives them does not inherit them, and neither do the
  configurations beside it.
- An integration can also record a package set selection for a
  configuration (`record.defaultPkgs`). It applies to that
  configuration and is inherited the same way.
- `systems` has to come from the systems allowed where the giving
  configuration is declared, and a system outside them is refused. A
  machine that holds an image for another architecture states that
  architecture there, and a configuration evaluated once can return a
  list to narrow what its children are evaluated for.

### Telling names apart: `elide`

`caisson-core.elide paths` gives, for each of a set of things in a
tree, the segments needed to tell it apart from the others.

- A path is the list of `{ type, name }` segments from the top down
  to the thing, ending in the name of the thing. A system is a
  segment of type `system`.
- The result has, for each path in order, the segments kept, as
  strings.

The rule keeps the last segment of every path, and beyond it only the
segments where paths that end in the same name fork. Among those
paths it drops the prefix they share, keeps the segment at which they
first differ, and does the same within each branch.

So a name that is alone stays bare, whatever sits above it, and names
that collide gain what tells them apart: `hostname1` evaluated for a
single system stays `hostname1`, and `hostname2` evaluated for
`x86_64-linux` and `aarch64-linux` keeps the system.

A segment is kept as its name, or as `type/name` where the branches
of that fork hold the same name under several types. How the kept
segments are written out as a name, and a clash between equal paths,
are for whoever publishes them.

### Finding a manifest: `manifestOf`

Every manifest carries `_type = "caisson-manifest"`, and `manifestOf`
finds it in whatever a file returns:

- a manifest;
- an attribute set carrying `caisson.manifest`;
- an evaluated configuration carrying `config.caisson.manifest`;
- a library, or a package set through `pkgs.lib`, carrying the phase
  manifests, where the last manifest filled in is the manifest.

It returns null when the value carries none.

Higher layers project the `libOverlays` and `modules` outputs of a
flake from the manifest, and the `projects` argument consumes those
projections one level down, which is how dictionaries populate across
flakes. The manifest carries no checks here: producers validate their
manifests, and consuming integrations type-check on the export side.

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
