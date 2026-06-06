# SpineSpriteProxy

A pure-GDScript render-separation proxy for [spine-godot](https://esotericsoftware.com/spine-godot). Lets you draw an unrelated node *between* the front and back halves of a Spine skeleton's draw order without duplicating the skeleton — the same idea as spine-unity's [`SkeletonRenderSeparator`](https://esotericsoftware.com/spine-unity-utility-components#SkeletonRenderSeparator), implemented entirely in GDScript so no custom Godot/Spine build is required.

**Background.** Originally proposed upstream as a C++ feature for spine-godot: [EsotericSoftware/spine-runtimes#3091](https://github.com/EsotericSoftware/spine-runtimes/pull/3091). Declined by the maintainers ("the godot runtime already supports this via slot nodes"). The case slot nodes *can't* express — where the source skeleton rides another skeleton via a `SpineBoneNode` and you want the host's body to draw between the source's back and front halves — is what motivated this script. The C++ version is preserved at [GameJawnsInc/spine-runtimes:godot-render-separation](https://github.com/GameJawnsInc/spine-runtimes/tree/godot-render-separation) if you want it as a real Godot module/extension.

## Requirements

- **Godot 4.5+** (developed against 4.6.2-stable).
- **Spine for Godot 4.3+** GDExtension installed in your project.

## Install

Copy **`SpineSpriteProxy.gd`** anywhere in your project's `res://`. That's it.

The script declares `class_name SpineSpriteProxy`, so once it's anywhere in the project Godot registers it globally — you can add `SpineSpriteProxy` nodes from the editor's "Add Child Node" dialog and reference the class from any other script without imports or autoloads. No plugin to enable, no folder structure to match.

## Running this repo's demo (optional)

If you cloned this repo and want to see `example.tscn` run, you need two things that aren't redistributed here (both are Esoteric Software's):

1. **Spine for Godot extension** at `bin/`:
   ```
   bin/
     spine_godot_extension.gdextension
     windows/libspine_godot.windows.editor.x86_64.dll
     windows/libspine_godot.windows.template_debug.x86_64.dll
     windows/libspine_godot.windows.template_release.x86_64.dll
     (and mac/linux/etc. as needed)
   ```
   Copy from your existing Spine-enabled Godot project, or from Esoteric Software's distribution.

2. **Skeleton assets** wherever the example/smoke-test scenes reference them — currently `assets/`. The example uses whatever skeletons you've configured the `.tscn` with; the smoke test references `assets/spineboy/spineboy-data-res.tres`. You can grab a default spineboy from [spine-runtimes/spine-godot/example-v4/assets/spineboy](https://github.com/EsotericSoftware/spine-runtimes/tree/4.3/spine-godot/example-v4/assets/spineboy).

Then open `project.godot` in Godot.

## How it works

`SpineSpriteProxy` extends `SpineSprite`. Place one in the scene, point its `source_sprite` at the SpineSprite whose slots you want to split, and set `start_slot_name` / `end_slot_name` to define the contiguous slot range this proxy renders. Four hooks fire per source tick:

1. **Restore** (`source.before_animation_state_apply`) — reset the source's claimed slot colors to their setup-pose color, so last frame's α=0 mask doesn't poison this frame's mirror. Spine's `AnimationState.apply` doesn't restore slot colors when there's no color timeline, so we have to.
2. **Mirror** (`source.before_world_transforms_change`) — copy the source's bone and slot state (post-anim, pre-world-transforms) onto the proxy's own skeleton: every bone's local pose, every slot's color/dark/attachment/sequence_index/deform.
3. **Source-mask** (`source.world_transforms_changed`) — zero α on the source's claimed slots, after the source's world transforms compute (so they're still computed correctly) but before its `update_meshes` reads slot colors.
4. **Self-mask** (proxy's own `before_world_transforms_change`) — zero α on the proxy's slots outside its claimed range.

The source drives all animation; the proxy is a passive mirror that never runs its own `AnimationState.apply` over its bones. For an N-way split, drop N-1 proxies on the same source with adjacent ranges — each independently restores/masks only its own range on the source, so they compose without coordination.

## Usage

In the editor, drop a `SpineSpriteProxy` node into your scene wherever you want the proxy's rendering to live (the parent controls layering via `z_index` / tree order). Inspector properties:

| Property | Description |
|----------|-------------|
| `source_sprite` | NodePath to the source `SpineSprite`. |
| `start_slot_name` | First slot in the range (inclusive). Empty string = slot 0. |
| `end_slot_name` | Last slot in the range (inclusive). Empty string = last slot. |
| `follow_source_transform` | If true (default), the proxy's `global_transform` follows the source's each frame. Set false if you want the proxy at a fixed scene position. |
| `skeleton_data_res` | Inherited from `SpineSprite`. Auto-synced to the source's at `_ready` if mismatched. |

The script is `@tool`, so the proxy works in editor preview too — scene-view layering reflects the configured setup live.

> **Don't call `set_animation()` on a proxy.** The proxy is a passive mirror — running its own animation state would silently overwrite the bones the mirror just copied. (`SpineSpriteProxy extends SpineSprite`, so the API is technically available, but it's a footgun. Drive animation only on the source.)

## Example

`example.tscn` is a render-separation demo of the case that motivated the project: a smaller skeleton is parented under a `SpineBoneNode` of a larger one (so it rides the host), and the *host's* body draws *between* the smaller skeleton's two halves. Layering is `z_index`-driven:

- Smaller skeleton (source): `z_index = -1` → its visible slots draw behind the host.
- Host skeleton: `z_index = 0`.
- `SpineSpriteProxy` (configured with the source NodePath and a `start_slot_name`): the rest of the source's slots, drawn above the host.

This case is what `SpineSlotNode` alone can't express, because the scene tree can't simultaneously hold "source rides host" and "host lives inside source."

## Smoke test

`smoke_test.tscn` is an automated test that authors a 2-way split on a spineboy and asserts:

1. **`BONE_MIRROR`** — every proxy bone's local pose matches source's.
2. **`ATTACHMENT_MIRROR`** — every proxy slot's attachment matches source's by name.
3. **`SOURCE_MASK`** — the source hides its claimed range, shows the rest.
4. **`PROXY_MASK`** — the proxy hides slots outside its range; in-range slots reflect source's pre-mask state.

Run headless:

```sh
godot --headless smoke_test.tscn
```

Exit code 0 = all pass.

## License

Code (`SpineSpriteProxy.gd`, the example, the smoke test) is MIT-licensed — see `LICENSE`.

The Spine for Godot extension and demo assets aren't redistributed here; both are Esoteric Software's and subject to the [Spine Runtimes License Agreement](https://esotericsoftware.com/spine-runtimes-license). You'll need them locally to run the example (see "Running this repo's demo").

## Credits

Developed by GameJawnsInc with Claude Code assistance.
