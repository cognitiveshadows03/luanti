# Minecraft Java mods — what is possible, and what is not

This note exists because "add support for Minecraft Java mods" is the one request
in this project that cannot be delivered as literally stated. It is worth being
precise about why, because the *useful* 70% of it absolutely can be built.

## Why a Java mod jar cannot run on Luanti

A Minecraft mod jar is a zip containing compiled `.class` bytecode plus assets
and data. The bytecode is not portable game content — it is code written against
Minecraft's own internals:

* it references `net.minecraft.*` classes directly (blocks, items, entity classes,
  the level, the registry, the tick loop);
* it registers content by calling Minecraft's registry APIs at a specific point
  in Minecraft's own startup sequence;
* Forge / NeoForge / Fabric mods additionally depend on a **mod loader**: an event
  bus, a lifecycle, and — for most modern mods — **Mixins**, a bytecode
  transformation system that rewrites Minecraft's classes at load time.

To run one you need Minecraft's class hierarchy, the loader's event bus, the mixin
transformer, and a JVM. Luanti has none of these and C++/Lua equivalents do not
substitute for them: the mod would be calling functions that do not exist, on
classes that do not exist, at a moment that does not exist.

## The strongest evidence: Horizon

The user pointed at [horizon-rust/horizon](https://github.com/horizon-rust/horizon)
as a reference. It is the most advanced Minecraft reimplementation available —
a Rust rewrite targeting **100% vanilla parity**, validated by 300+ differential
harnesses against the real Java game, supporting vanilla worldgen, redstone,
every command, and upgrading worlds from 1.8 to 26.3.

Its own documentation says:

> **Fabric and NeoForge jars do not run as they are**: their code calls and
> patches Minecraft's Java classes, and Horizon has none. What carries over is
> the data and assets inside a jar.

So even a project that has reimplemented essentially all of Minecraft from
scratch cannot execute Java mods. This is not a limitation of Luanti's design or
of this fork — it is inherent to what a mod jar is.

## What *does* carry over — and what we can build

The valuable content inside most jars is not the code. It is the data:

| Inside the jar | Portable? | Maps onto Luanti as |
|---|---|---|
| `assets/<ns>/textures/**.png` | **Yes** — plain 16×16 PNGs | node/item textures |
| `assets/<ns>/models/block/*.json` | **Yes**, for cube-style models | node `tiles` |
| `assets/<ns>/lang/en_us.json` | **Yes** | item/node descriptions |
| `data/<ns>/recipes/*.json` | **Yes** | `minetest.register_craft` |
| `data/<ns>/loot_tables/**` | **Yes** | drop tables |
| `data/<ns>/tags/**` | **Yes** | item groups |
| `data/<ns>/worldgen/**` | Partly | biome/ore registration |
| `*.class` | **No** | — |

This is exactly the "content mod" path Horizon itself converged on
(`.hmod`: manifest + `assets/` + `data/`, no code). We can do the same thing in
Lua, because **all of the above is readable straight out of the zip without a
JVM** — a jar is just a zip.

### Proposed: a jar importer for Luanti

A converter that takes a `.jar` and emits a Luanti mod folder:

1. Read the zip central directory (pure Lua `inflate` is required, since most
   entries are DEFLATE-compressed).
2. Parse `fabric.mod.json` / `META-INF/mods.toml` for the mod id, name, version
   and licence — used to name the output mod and to warn about dependencies.
3. Walk `assets/` and `data/`:
   * textures are copied verbatim (Minecraft and VoxeLibre already share the
     `default_*` / namespace naming, so most land correctly);
   * `models/block/cube_all.json` → a node with one tile on all six faces;
     `cube.json`/`orientable.json` → per-face tiles;
   * `recipes/*.json` (shaped/shapeless) → `minetest.register_craft`;
   * `lang/en_us.json` → `description` fields and aliases.
4. Emit `mod.conf`, `init.lua`, `textures/`, and a `CONVERSION_REPORT.txt`
   listing exactly what converted, what was approximated, and what was skipped.
5. For anything that only existed as code, fail loudly per-file rather than
   silently producing a half-broken mod — a mod that adds blocks via a
   `BlockBehaviour` subclass will produce textures with no blocks, and the report
   must say so.

Realistic coverage: **simple "adds blocks/items/decor" mods convert well**.
Mods whose content is generated in code (most tech mods, most magic mods) will
convert to their textures and nothing else, and the report will say why.

## What must not be done

* **Do not bundle Minecraft assets.** Luanti cannot ship Mojang's textures,
  sounds or models. Anything imported must come from jars the user already has.
  (VoxeLibre's art is independently licensed, which is why it can ship.)
* **Do not pretend code mods work.** A jar whose blocks are registered in Java
  will produce textures and no gameplay. Silently accepting it is worse than
  refusing it.

## Honest status

| Request | Status |
|---|---|
| Run Fabric / Forge / NeoForge jars | **Not feasible.** Not feasible for any reimplementation; see above. |
| Convert jar data + assets into playable Luanti content | **Feasible and worth building.** Needs a zip/inflate reader in Lua plus the mapping table above. |
| Resource packs (textures, models, lang) | **Feasible, easiest win.** A resource pack is the same `assets/` layout with no code. |
| Data packs (recipes, loot, worldgen) | **Feasible.** Same `data/` mapping. |

If you want Java-mod support in this project, the deliverable is the **jar
importer** — and the first milestone should be resource packs, because they are
pure assets, carry no code, and prove the pipeline end to end.
