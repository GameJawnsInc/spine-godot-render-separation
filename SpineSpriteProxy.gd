@tool
class_name SpineSpriteProxy
extends SpineSprite

## Render-separation proxy. Place this node in the scene, point
## [member source_sprite] at a SpineSprite, and set [member start_slot_name] /
## [member end_slot_name] to define the contiguous slot range this proxy renders.
## The source is masked over that range so it doesn't double-draw.
##
## The proxy mirrors the source's bone and slot state each frame; it doesn't run
## its own animation. To split a skeleton N ways, place N-1 proxies on the same
## source with adjacent ranges — each proxy independently restores/masks only
## its own range on the source, so they compose without coordination.
##
## [b]Per-tick lifecycle, five hooks:[/b]
## [br]1. [i]Restore[/i] (source.before_animation_state_apply) — reset every
##   source slot's color to its setup-pose color so last frame's α=0 mask
##   doesn't poison this frame's mirror. Restored unconditionally because
##   the claim can vary frame-to-frame with draw-order animations.
## [br]2. [i]Mirror[/i] (source.before_world_transforms_change) — copy bone
##   local poses and slot state from source to proxy.
## [br]3. [i]Source-mask[/i] (source.world_transforms_changed) — compute this
##   frame's claim from the source's current draw order, zero α on the claimed
##   slots. Runs unconditionally — hiding the proxy hides those slots
##   entirely (proxy doesn't draw, source doesn't either). To restore source
##   rendering for the range, detach the proxy or clear [member source_sprite].
## [br]4. [i]Self-mask[/i] (own before_world_transforms_change) — zero α on
##   our own slots that are NOT in this frame's claim.
## [br]5. [i]Mirror world[/i] (own world_transforms_changed) — after the
##   proxy's own update_world_transform pass, override its bone world
##   transforms with the source's final world transforms. Bypasses any
##   constraint divergence (IK / transform / path / physics state that
##   accumulates differently between the source's skeleton and ours).
##
## [b]Claim semantics:[/b] [member start_slot_name] and [member end_slot_name]
## are resolved against the source's [i]current draw order[/i] each frame, not
## the static slot-index range. A slot that draws between start and end in
## the running animation is in the claim regardless of its setup-pose index,
## so DrawOrderTimelines in the animation are respected.
##
## [b]Footgun:[/b] do not call [code]set_animation()[/code] on a proxy.
## Because the proxy extends SpineSprite, the API is inherited — but the proxy
## is a passive mirror, and running its own animation state would overwrite
## the bones the mirror just copied. Drive animation only on the source.
##
## [b]Known limitation:[/b] the slot-name dropdowns are populated from the
## source's current skeleton. If you change the source's [code]skeleton_data_res[/code]
## without re-poking this proxy's [member source_sprite], the dropdowns stay
## stale until you re-pick the NodePath.

@export var source_sprite: NodePath:
	set(v):
		source_sprite = v
		_rewire()
		notify_property_list_changed()  # repopulate slot dropdowns

# Not @export — exposed via _get_property_list() below so the inspector shows
# them as dropdowns of the source skeleton's slot names instead of free-text.
var start_slot_name: String = "":
	set(v):
		start_slot_name = v
		_rewire()

var end_slot_name: String = "":
	set(v):
		end_slot_name = v
		_rewire()

## When true, the proxy's global_transform follows the source's each frame.
## Set false to render the source's slots at the proxy's own scene-tree transform.
@export var follow_source_transform: bool = true

## When true (default), the proxy's [member visible] follows the source's
## effective [method is_visible_in_tree]. Hiding the source — or any ancestor
## of it — also hides the proxy, preventing a frozen-pose render of the
## proxy while the source has stopped processing. Set false if you want to
## drive the proxy's visibility independently.
@export var hide_with_source: bool = true:
	set(v):
		hide_with_source = v
		_sync_visibility()

# --- internal state ---
var _source: SpineSprite
# Slot indices claimed this frame, recomputed from the source's current
# draw order in _mask_source and consumed in _mask_self. Empty when the
# proxy is hidden (so the source draws everything).
var _claimed_indices: Dictionary = {}
# Proxy's physics constraints, cached at _resolve_and_connect for per-frame
# reset. Spine 4.3 physics integrates with internal state (velocities,
# offsets) that diverges from the source's; resetting each frame keeps the
# proxy's physics in its "skip integration" branch so our world-transform
# override isn't fighting an independent simulation. Empty when no physics
# constraints exist (or get_physics_constraints isn't bound in the build).
var _proxy_physics_constraints: Array = []

# --- lifecycle ---

func _get_property_list() -> Array:
	# Build start_slot_name / end_slot_name as dropdowns sourced from the
	# resolved source's slot names. HINT_ENUM_SUGGESTION = dropdown + free
	# text, so the "" empty-endpoint sentinel still works (type empty into
	# the field) and the user isn't locked out if the source hasn't resolved.
	var slot_names := PackedStringArray()
	if is_inside_tree() and not source_sprite.is_empty():
		var src := get_node_or_null(source_sprite) as SpineSprite
		if src != null:
			var skel := src.get_skeleton()
			if skel != null:
				for slot in skel.get_slots():
					slot_names.append(slot.get_data().get_name())
	var hint_string := ",".join(slot_names)
	return [
		{
			"name": "start_slot_name",
			"type": TYPE_STRING,
			"hint": PROPERTY_HINT_ENUM_SUGGESTION,
			"hint_string": hint_string,
			"usage": PROPERTY_USAGE_DEFAULT,
		},
		{
			"name": "end_slot_name",
			"type": TYPE_STRING,
			"hint": PROPERTY_HINT_ENUM_SUGGESTION,
			"hint_string": hint_string,
			"usage": PROPERTY_USAGE_DEFAULT,
		},
	]

func _ready() -> void:
	_rewire()

func _exit_tree() -> void:
	_disconnect()

# Re-resolve and re-wire when any export changes (or _ready fires).
# Bails when called before the node enters the tree (setters fire during
# scene-load property assignment, before _ready).
func _rewire() -> void:
	if not is_inside_tree():
		return
	_disconnect()
	_resolve_and_connect()

func _resolve_and_connect() -> void:
	if source_sprite.is_empty():
		return
	var src := get_node_or_null(source_sprite) as SpineSprite
	if src == null:
		push_warning("SpineSpriteProxy: source_sprite must point to a SpineSprite")
		return
	if src == self:
		push_warning("SpineSpriteProxy: source_sprite points to this proxy itself; ignoring.")
		return
	_source = src

	# Match source's skeleton data so our own skeleton has matching slot/bone layout.
	if skeleton_data_res != _source.skeleton_data_res:
		skeleton_data_res = _source.skeleton_data_res

	var skel := _source.get_skeleton()
	if skel == null:
		return

	# Validate slot names exist. They're resolved each frame against the
	# source's current draw order; if missing, _compute_claim falls back to
	# an open endpoint (first / last slot in draw order).
	var slot_names_set := {}
	for s in skel.get_slots():
		slot_names_set[s.get_data().get_name()] = true
	if start_slot_name != "" and not slot_names_set.has(start_slot_name):
		push_warning("SpineSpriteProxy: start_slot_name '%s' not found in source skeleton; using first slot in draw order." % start_slot_name)
	if end_slot_name != "" and not slot_names_set.has(end_slot_name):
		push_warning("SpineSpriteProxy: end_slot_name '%s' not found in source skeleton; using last slot in draw order." % end_slot_name)

	# Tick after source so updateWorldTransform reads mirrored bones.
	process_priority = _source.process_priority + 1

	# Hooks. Three things have to happen per source tick, in order:
	#   1. Restore — set source slot colors back to setup-pose color BEFORE
	#      animation applies. Spine's AnimationState.apply doesn't reset slot
	#      colors when there's no color timeline, so without this our α=0
	#      mask from last frame would persist and the mirror would read stale
	#      zeros. We restore EVERY slot (not just the claim) because the claim
	#      can change frame-to-frame with draw-order animations.
	#   2. Mirror — copy source's now-fresh bone+slot state to proxy AFTER
	#      apply runs and BEFORE source's world transforms.
	#   3. Source-mask — compute this frame's claim from the source's current
	#      draw order, then zero α on the claimed slots AFTER world transforms
	#      and BEFORE source's update_meshes. Runs unconditionally — hiding
	#      the proxy hides those slots entirely (proxy doesn't draw, source
	#      doesn't either).
	_source.before_animation_state_apply.connect(_restore_source)
	_source.before_world_transforms_change.connect(_mirror)
	_source.world_transforms_changed.connect(_mask_source)
	_source.visibility_changed.connect(_sync_visibility)
	before_world_transforms_change.connect(_mask_self)
	world_transforms_changed.connect(_mirror_world)
	_sync_visibility()  # initial sync — source may already be invisible

	# Cache proxy's physics constraints for per-frame reset (see _mirror_world).
	# Use a feature check because get_physics_constraints isn't bound in
	# every spine-godot build; we degrade gracefully if it's missing.
	_proxy_physics_constraints.clear()
	var data_res := _source.skeleton_data_res
	var has_enum: bool = data_res != null and data_res.has_method("get_physics_constraints")
	if has_enum:
		for data in data_res.get_physics_constraints():
			if data != null and data.has_method("get_constraint_name"):
				var cname: String = data.get_constraint_name()
				var rt = get_skeleton().find_physics_constraint(cname)
				if rt != null:
					_proxy_physics_constraints.append(rt)
	# Diagnostic: print once at setup so we can confirm enumeration worked.
	print("[SpineSpriteProxy] enum bound: %s | cached %d physics constraint(s) for reset" \
		% [has_enum, _proxy_physics_constraints.size()])

	# Initial mirror so the first frame doesn't flash setup pose.
	_mirror(null)

func _disconnect() -> void:
	if _source and is_instance_valid(_source):
		if _source.before_animation_state_apply.is_connected(_restore_source):
			_source.before_animation_state_apply.disconnect(_restore_source)
		if _source.before_world_transforms_change.is_connected(_mirror):
			_source.before_world_transforms_change.disconnect(_mirror)
		if _source.world_transforms_changed.is_connected(_mask_source):
			_source.world_transforms_changed.disconnect(_mask_source)
		if _source.visibility_changed.is_connected(_sync_visibility):
			_source.visibility_changed.disconnect(_sync_visibility)
		# Restore source's slot colors to setup so the source draws its full
		# skeleton again after we detach. We restore ALL slots because the
		# claim can vary frame-to-frame with draw-order animations, so we
		# don't reliably know what we last masked. Color-only (not full
		# set_to_setup_pose) so attachment/deform/sequence state survives;
		# the source's next animation tick will overwrite color as needed.
		var skel := _source.get_skeleton()
		if skel != null:
			for slot in skel.get_slots():
				var pose = slot.get_pose()
				var data = slot.get_data()
				pose.set_color(data.get_color())
	if before_world_transforms_change.is_connected(_mask_self):
		before_world_transforms_change.disconnect(_mask_self)
	if world_transforms_changed.is_connected(_mirror_world):
		world_transforms_changed.disconnect(_mirror_world)
	_source = null
	_claimed_indices = {}
	_proxy_physics_constraints.clear()

# --- mirror & mask hooks ---

func _mirror(_s) -> void:
	if not is_instance_valid(_source):
		return
	var src_skel := _source.get_skeleton()
	var dst_skel := get_skeleton()
	if src_skel == null or dst_skel == null:
		return

	# Bones: copy local pose. Loops are bound to min() so a transient skeleton
	# mismatch (e.g. source's skeleton_data_res just changed but ours hasn't
	# re-initialized yet) can't index out of range.
	var src_bones := src_skel.get_bones()
	var dst_bones := dst_skel.get_bones()
	var bone_n: int = min(src_bones.size(), dst_bones.size())
	for i in bone_n:
		var a = src_bones[i].get_pose()
		var b = dst_bones[i].get_pose()
		b.set_x(a.get_x()); b.set_y(a.get_y())
		b.set_rotation(a.get_rotation())
		b.set_scale_x(a.get_scale_x()); b.set_scale_y(a.get_scale_y())
		b.set_shear_x(a.get_shear_x()); b.set_shear_y(a.get_shear_y())
		b.set_inherit(a.get_inherit())

	# Slots: color, dark color, attachment, sequence index, deform (FFD).
	var src_slots := src_skel.get_slots()
	var dst_slots := dst_skel.get_slots()
	var slot_n: int = min(src_slots.size(), dst_slots.size())
	for i in slot_n:
		var a = src_slots[i].get_pose()
		var b = dst_slots[i].get_pose()
		b.set_color(a.get_color())
		b.set_has_dark_color(a.has_dark_color())
		if a.has_dark_color():
			b.set_dark_color(a.get_dark_color())
		b.set_attachment(a.get_attachment())
		b.set_sequence_index(a.get_sequence_index())
		b.set_deform(a.get_deform())

	# Also sync transform here, not just in _process. Engine internal-process
	# vs _process order is implementation-dependent, and runtime tick order
	# differs from editor preview; setting it here as well guarantees the
	# proxy's update_skeleton this frame computes against source's current
	# global_transform. _process still handles the "source invisible, no
	# signal" case.
	if follow_source_transform:
		global_transform = _source.global_transform


func _process(_delta: float) -> void:
	# Track the source's global_transform every frame, independent of either
	# node's visibility. Spine's update_skeleton bails when the source is
	# hidden, so the mirror hook on source.before_world_transforms_change
	# doesn't fire — but the source's Node2D transform still updates from
	# its parent chain (e.g. a tween on the monster), and we want to keep
	# tracking so when the source becomes visible again the proxy is already
	# in place. Matches the C++ render-separator's behavior.
	if follow_source_transform and is_instance_valid(_source):
		global_transform = _source.global_transform

func _restore_source(_s) -> void:
	# Reset EVERY source slot's color to setup before apply runs, so the
	# previous frame's α=0 mask doesn't poison this frame's mirror. We restore
	# all slots (not just the current claim) because the claim can change
	# frame-to-frame with draw-order animations — we don't know which slots
	# we masked last frame. Apply will overwrite as needed.
	if not is_instance_valid(_source):
		return
	var skel := _source.get_skeleton()
	if skel == null:
		return
	for slot in skel.get_slots():
		var pose = slot.get_pose()
		var data = slot.get_data()
		pose.set_color(data.get_color())

func _mask_source(_s) -> void:
	# Compute this frame's claim from the source's current draw order, then
	# zero α on the claimed slots. With N proxies the source's hidden slots
	# are the union of every proxy's claim. Runs even when the proxy is
	# hidden — that's intentional: hiding the proxy hides those slots
	# entirely (proxy doesn't draw, source doesn't either). If you want the
	# source to redraw them, detach the proxy (queue_free or clear
	# source_sprite), don't just hide it.
	if not is_instance_valid(_source):
		return
	var skel := _source.get_skeleton()
	if skel == null:
		return
	_claimed_indices = _compute_claim(skel)
	var slots := skel.get_slots()
	for idx in _claimed_indices:
		var pose = slots[idx].get_pose()
		var c = pose.get_color()
		c.a = 0.0
		pose.set_color(c)

func _sync_visibility() -> void:
	# Mirror source's effective visibility to ourselves. Fired from source's
	# visibility_changed signal (which propagates through ancestor changes
	# too — hiding any parent of source triggers it). Without this the proxy
	# would remain visible rendering a frozen pose when the source has
	# stopped processing.
	if not hide_with_source:
		return
	if not is_instance_valid(_source):
		return
	var src_visible := _source.is_visible_in_tree()
	if visible != src_visible:
		visible = src_visible

func _mirror_world(_s) -> void:
	# Override the proxy's bone WORLD transforms with the source's, AFTER the
	# proxy's own update_world_transform has run but BEFORE its update_meshes.
	# This bypasses any constraint divergence (IK, transform, path, physics)
	# between the source's skeleton and ours: the proxy renders the source's
	# exact world pose, regardless of how the two skeletons' constraints
	# would each compute it from the same local poses.
	#
	# Critical: read/write get_applied_pose(), not get_pose(). Constrained
	# bones (anything driven by IK/Transform/Path/Physics) have a separate
	# _constrainedPose that get_applied_pose() points at — and that's the
	# one the renderer reads. Writing to get_pose() would set the wrong
	# BonePose for any constrained bone, which is the root of every IK
	# chain in a typical rig (legs, arms). See spine-cpp Posed.h:93.
	if not is_instance_valid(_source):
		return
	var src_skel := _source.get_skeleton()
	var dst_skel := get_skeleton()
	if src_skel == null or dst_skel == null:
		return
	var src_bones := src_skel.get_bones()
	var dst_bones := dst_skel.get_bones()
	var n: int = min(src_bones.size(), dst_bones.size())
	for i in n:
		var s = src_bones[i].get_applied_pose()
		var d = dst_bones[i].get_applied_pose()
		# Local fields. Matter for physics continuity — Spine 4.3 physics
		# constraints use applied_pose.local as integration state across
		# frames, and a divergence here can compound visually even after
		# world transforms are corrected.
		d.set_x(s.get_x())
		d.set_y(s.get_y())
		d.set_rotation(s.get_rotation())
		d.set_scale_x(s.get_scale_x())
		d.set_scale_y(s.get_scale_y())
		d.set_shear_x(s.get_shear_x())
		d.set_shear_y(s.get_shear_y())
		d.set_inherit(s.get_inherit())
		# World fields. These are what the renderer reads (RegionAttachment.cpp
		# / VertexAttachment.cpp read getAppliedPose().getA() etc).
		d.set_a(s.get_a())
		d.set_b(s.get_b())
		d.set_c(s.get_c())
		d.set_d(s.get_d())
		d.set_world_x(s.get_world_x())
		d.set_world_y(s.get_world_y())

	# Reset our physics constraints so next frame's physics pass skips
	# integration (the if-_reset branch in PhysicsConstraint::update sets
	# the baselines to the current bone position and returns without
	# modifying anything). Our world-transform override is then the
	# only authority — proxy never accumulates an independent physics sim.
	for c in _proxy_physics_constraints:
		if c != null:
			c.reset(dst_skel)

func _mask_self(_s) -> void:
	# Zero our own slot colors for everything NOT in this frame's claim
	# (set by _mask_source on the source's tick, which fires before ours).
	var skel := get_skeleton()
	if skel == null:
		return
	var slots := skel.get_slots()
	for i in slots.size():
		if not _claimed_indices.has(i):
			var pose = slots[i].get_pose()
			var c = pose.get_color()
			c.a = 0.0
			pose.set_color(c)

# Walk the source's current draw order to find positions of start_slot_name /
# end_slot_name, then collect the slot indices appearing at those draw
# positions. Returns a Dictionary used as a set (slot_index → true).
func _compute_claim(skel: SpineSkeleton) -> Dictionary:
	var draw_order := skel.get_draw_order()
	var lo := 0
	var hi := draw_order.size()
	if start_slot_name != "":
		for i in draw_order.size():
			if draw_order[i].get_data().get_name() == start_slot_name:
				lo = i; break
	if end_slot_name != "":
		for i in draw_order.size():
			if draw_order[i].get_data().get_name() == end_slot_name:
				hi = i + 1; break  # inclusive end
	var claim: Dictionary = {}
	if lo < hi:
		for i in range(lo, hi):
			claim[draw_order[i].get_data().get_index()] = true
	return claim
