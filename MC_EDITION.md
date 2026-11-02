# Minecraft Edition

This branch turns the vanilla Luanti engine into something that plays and looks
like **stock Minecraft (Bedrock-style)** out of the box, while staying as light
as possible on old phones.

Everything here is *engine-side*, so it stays small: no extra binary bloat, no
new third-party libraries, no rendering rewrite. The "Minecraft look" comes from
bundling a real Minecraft-content game (VoxeLibre), and the weight reduction
comes from a few hundred lines of C++.

---

## What changed

### 1. Automatic low-end quality profile

`src/defaultsettings.cpp`

The engine now measures the device once at startup and picks a quality tier by
itself. The user never has to open the settings menu.

| Tier     | Detected when                        | View range | FPS cap | Leaves  | Smooth light | 3D clouds | Mesh chunk | Mapblock budget |
|----------|--------------------------------------|-----------:|--------:|---------|--------------|-----------|-----------:|----------------:|
| `potato` | ≤ 1.4 GB RAM, or ≤ 2 cores          |         56 |      30 | opaque  | off          | off       |          4 |        1200 (~19 MB) |
| `low`    | ≤ 2.9 GB RAM, or a screen > 1080p    |         72 |      40 | simple  | on           | off       |          3 |        2000 (~32 MB) |
| `mid`    | ≤ 5.5 GB RAM                         |         96 |      60 | fancy   | on           | on        |          2 |        2600 (~41 MB) |
| `high`   | everything else                      |        128 |      60 | fancy   | on           | on        |          2 |        3400 (~54 MB) |

Two things are worth calling out:

* **Mesh chunk size is raised on weak devices** (4 instead of 2). Counter-
  intuitively, this *helps* low-end GPUs: fewer, larger draw calls cost less
  than many small ones, and it cuts per-frame CPU work.
* **The profile reaches into the game too.** VoxeLibre reads settings such as
  `mcl_weather_rain_particles` and `mcl_mob_cap_total` through
  `minetest.settings`. Because these are set as *engine defaults*, the game
  picks them up with no patching of the game itself. On a potato tier you get
  100 rain particles instead of 500 and a 160-mob cap instead of 500.

The detected tier is also exposed to Lua as **`luanti_perf_tier`**
(`"potato" | "low" | "mid" | "high"`) so any game can adapt further.

Every value is a *default* only — anything in the user's `minetest.conf` still
wins, and the in-game settings menu still shows everything as editable.

### 2. Minecraft-style touch controls

`src/gui/touchscreenlayout.cpp`, `src/gui/touchscreenlayout.h`,
`src/defaultsettings.cpp`, `builtin/settingtypes.txt`

New setting `touch_layout_preset` (`luanti` | `minecraft`), defaulting to
`minecraft` on Android. The Minecraft preset is a compact 2×2 thumb diamond in
the bottom-right corner:

```
                              ┌──────┐
                              │ chat │
                              ├──────┤
                              │  ☰   │      (overflow menu)
   ┌──────┐                   └──────┘
   │ fly  │  ┌──────┐
   ├──────┼──┼──────┤
   │ inv  │  │sneak │
   └──────┴──┴──────┘  ┌──────┐
                       │ jump │
        joystick       └──────┘
        (bottom-left)
```

No zoom, aux1 or minimap buttons, because stock Minecraft has none. Jump sits
closest to the corner where the thumb rests; the movement joystick stays in the
bottom-left, exactly like Minecraft.

Also enabled by default on Android for a Minecraft-like feel:
`fixed_virtual_joystick`, higher touch sensitivity, and `autojump`.

### 3. Stock-Minecraft visual defaults

```ini
fov = 70                  # Minecraft's default field of view
view_bobbing_amount = 1.0 # Minecraft head bobbing
node_highlighting = box   # the black block-selection outline
selectionbox_width = 2
crosshair_alpha = 255
enable_dig_particles = true
cinematic = false
```

### 4. A bundled game, so it *is* Minecraft

`games/voxelibre/` — [VoxeLibre](https://github.com/VoxeLibre/VoxeLibre)
(previously MineClone2), the mature Minecraft-content game for Luanti. It ships
Minecraft-authentic 16×16 textures, blocks, mobs, crafting, redstone, the Nether
and the End.

It is vendored into the repo (rather than downloaded at build time) so it can be
edited in place, and so builds work offline.

`android/app/build.gradle` now packs `games/` into the APK assets, so a fresh
install can start playing immediately with no content download. `devtest` is
excluded from the APK to keep it small.

The main menu already auto-selects the first non-devtest game, so VoxeLibre is
what you get on first launch.

---

## Building

### Desktop / server (verified)

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DRUN_IN_PLACE=TRUE
ninja -C build
./bin/luanti                # client
./bin/luantiserver --gameid voxelibre
```

### Android APK

```sh
cd android
./gradlew assembleRelease     # or assembleDebug
```

Requires JDK 17, Android SDK 36 and the NDK. The `.github/workflows/android.yml`
workflow builds both an AAB and APKs automatically on push.

> The APK will be large (~100 MB+ per ABI) because a full Minecraft-content game
> is inside it — that is inherent to shipping the game, not engine bloat. Per-ABI
> splits are already configured, and `armeabi-v7a` is the one to hand to old
> 32-bit devices.

---

## Verification performed

* Full Release build of `luanti` and `luantiserver` — clean, no errors.
* `luantiserver --gameid voxelibre` — VoxeLibre boots, LuaJIT parameters
  raised, world generated, no errors.
* Auto-profiling probe on a 2 GB / 2-core machine correctly reported
  `luanti_perf_tier = potato` and applied `viewing_range = 56`,
  `fps_max = 30`, `client_mesh_chunk = 4`, and propagated
  `mcl_weather_rain_particles = 100` / `mcl_mob_cap_total = 160` into the game.

---

## Ideas for the next pass

* Minecraft-style main menu (dirt/stone background, MC button styling) —
  `builtin/mainmenu/` is Luanti's boxy default and is the biggest remaining
  visual gap.
* A thin Minecraft-style crosshair and HUD relayout.
* Reduce the first-run cost of `assets.zip` extraction on slow storage.
* Optional: drop `menu/` background PNGs from the APK assets on the potato tier.

---

## Android touch controls (MCPE match)

![layout] The `minecraft` touch preset follows the Pocket Edition reference:

```
 ┌──────────────────────────────────────────────────────────┐
 │                                    [⋯] [chat]            │
 │                           [fly] [↑ jump]                 │
 │                     [grid][hand] [↓ sneak]               │
 │       ┌────────┐                                     │
 │       │        │            [sword]                     │
 │       │  stick │                                        │
 │       └────────┘   ▓▓ hotbar ▓▓                         │
 └──────────────────────────────────────────────────────────┘
```

Regenerate the button art at any time with:

```sh
python3 util/mc_edition/gen_touch_textures.py
```

It is all procedural (bevelled stone plates, sword/hand/grid glyphs, translucent
rounded-square joystick, plain white crosshair) so nothing is ripped from
Minecraft and the repo stays license-clean.

`touch_interaction_style` defaults to `buttons_crosshair` on Android, so the
sword and hand buttons dig and place the way MCPE does instead of tapping
through the crosshair.

## Signed APK

`.github/workflows/android-signed.yml` produces signed APKs for all four ABIs,
verifies each with `apksigner`, uploads them as artifacts and attaches them to
the GitHub Release when you push a `v*` tag.

Add these repository secrets to sign with your own key:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | key alias |
| `ANDROID_KEY_PASSWORD` | key password |

Without them the workflow still builds and uploads **debug-signed** APKs so you
can install on a device immediately; it emits a warning telling you what is
missing.

## Java mods

See [JAVA_MODS.md](JAVA_MODS.md) — a full, sourced explanation of why Fabric /
Forge jars cannot run (including the reference project's own documentation), and
the jar-data importer that is the actually-buildable alternative.
