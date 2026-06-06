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
## source with adjacent ranges.

@export var source_sprite: NodePath:
	set(v):
		source_sprite = v
		_rewire()

@export var start_slot_name: String = "":
	set(v):
		start_slot_name = v
		_rewire()

@export var end_slot_name: String = "":
	set(v):
		end_slot_name = v
		_rewire()

## When true, the proxy's global_transform follows the source's each frame.
## Set false to render the source's slots at the proxy's own scene-tree transform.
@export var follow_source_transform: bool = true

# --- internal state ---
var _source: SpineSprite
var _slot_lo: int = 0     # inclusive
var _slot_hi: int = 0     # exclusive

# --- lifecycle ---

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
	_source = src

	# Match source's skeleton data so our own skeleton has matching slot/bone layout.
	if skeleton_data_res != _source.skeleton_data_res:
		skeleton_data_res = _source.skeleton_data_res

	var skel := _source.get_skeleton()
	if skel == null:
		return
	var slots := skel.get_slots()

	# Resolve slot range. Empty strings = open endpoint (slot 0 / last slot).
	_slot_lo = 0
	_slot_hi = slots.size()
	if start_slot_name != "":
		var found := false
		for s in slots:
			if s.get_data().get_name() == start_slot_name:
				_slot_lo = s.get_data().get_index(); found = true; break
		if not found:
			push_warning("SpineSpriteProxy: start_slot_name '%s' not found in source skeleton; using slot 0." % start_slot_name)
	if end_slot_name != "":
		var found := false
		for s in slots:
			if s.get_data().get_name() == end_slot_name:
				_slot_hi = s.get_data().get_index() + 1; found = true; break
		if not found:
			push_warning("SpineSpriteProxy: end_slot_name '%s' not found in source skeleton; using last slot." % end_slot_name)
	if _slot_lo >= _slot_hi:
		push_warning("SpineSpriteProxy: slot range [%d, %d) is empty; proxy will draw nothing." % [_slot_lo, _slot_hi])

	# Tick after source so updateWorldTransform reads mirrored bones.
	process_priority = _source.process_priority + 1

	# Hooks. Three things have to happen per source tick, in order:
	#   1. Restore — set source's claimed slot colors back to setup-pose color
	#      BEFORE animation applies. Spine's AnimationState.apply doesn't
	#      reset slot colors when there's no color timeline, so without this
	#      our α=0 mask from last frame would persist and the mirror would
	#      read stale zeros.
	#   2. Mirror — copy source's now-fresh bone+slot state to proxy AFTER
	#      apply runs and BEFORE source's world transforms.
	#   3. Source-mask — zero source's claimed slots AFTER world transforms
	#      and BEFORE source's update_meshes (so source renders without them
	#      but world transforms were computed from the unmasked pose).
	_source.before_animation_state_apply.connect(_restore_source_range)
	_source.before_world_transforms_change.connect(_mirror)
	_source.world_transforms_changed.connect(_mask_source_range)
	before_world_transforms_change.connect(_mask_self)

	# Initial mirror so the first frame doesn't flash setup pose.
	_mirror(null)

func _disconnect() -> void:
	if _source and is_instance_valid(_source):
		if _source.before_animation_state_apply.is_connected(_restore_source_range):
			_source.before_animation_state_apply.disconnect(_restore_source_range)
		if _source.before_world_transforms_change.is_connected(_mirror):
			_source.before_world_transforms_change.disconnect(_mirror)
		if _source.world_transforms_changed.is_connected(_mask_source_range):
			_source.world_transforms_changed.disconnect(_mask_source_range)
		# Restore source's slot colors for our claimed range, so the source draws
		# its full skeleton again after we detach.
		var skel := _source.get_skeleton()
		if skel != null:
			var slots := skel.get_slots()
			for i in range(_slot_lo, min(_slot_hi, slots.size())):
				slots[i].set_to_setup_pose()
	if before_world_transforms_change.is_connected(_mask_self):
		before_world_transforms_change.disconnect(_mask_self)
	_source = null

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

	if follow_source_transform:
		global_transform = _source.global_transform

func _restore_source_range(_s) -> void:
	# Set source's claimed slots back to setup-pose color before apply runs,
	# so the previous frame's α=0 mask doesn't poison this frame's mirror.
	# If the animation has a color timeline for the slot, apply will override.
	if not is_instance_valid(_source):
		return
	var slots := _source.get_skeleton().get_slots()
	for i in range(_slot_lo, min(_slot_hi, slots.size())):
		var pose = slots[i].get_pose()
		var data = slots[i].get_data()
		pose.set_color(data.get_color())

func _mask_source_range(_s) -> void:
	# Zero source's slot colors for the range THIS proxy claims. With N proxies,
	# the source's hidden slots are the union of every proxy's claimed range.
	if not is_instance_valid(_source):
		return
	var slots := _source.get_skeleton().get_slots()
	for i in range(_slot_lo, min(_slot_hi, slots.size())):
		var pose = slots[i].get_pose()
		var c = pose.get_color()
		c.a = 0.0
		pose.set_color(c)

func _mask_self(_s) -> void:
	# Zero our own slot colors for everything OUTSIDE [_slot_lo, _slot_hi).
	var slots := get_skeleton().get_slots()
	for i in slots.size():
		if i < _slot_lo or i >= _slot_hi:
			var pose = slots[i].get_pose()
			var c = pose.get_color()
			c.a = 0.0
			pose.set_color(c)
