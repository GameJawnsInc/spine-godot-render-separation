extends Node2D

# Automated smoke test for SpineSpriteProxy. Builds a 2-way split, ticks for
# a few frames, then asserts:
#   1. BONE_MIRROR        — every proxy bone's local pose matches source's.
#   2. ATTACHMENT_MIRROR  — every proxy slot's attachment matches source's
#                            (verifies attachment refs are valid across skeletons).
#   3. SOURCE_MASK        — source hides [split, end), shows [0, split).
#   4. PROXY_MASK         — proxy hides [0, split), shows [split, end) at α>0
#                            (catches the "mirror reads masked state" bug).
#
# Run headless: godot --headless smoke_test.tscn
# Exit code 0 = all pass; 1 = any fail.

@onready var source: SpineSprite = $Source
@onready var proxy: SpineSpriteProxy = $Proxy

var frames: int = 0
var exit_code: int = 0
const TEST_FRAMES: int = 30
const SPLIT_SLOT: String = "front-upper-arm"

func _ready() -> void:
	source.get_animation_state().set_animation("walk", true, 0)
	# Proxy is authored in the scene with source_sprite → ../Source and
	# start_slot_name → "front-upper-arm". Its own _ready wired it up.
	print("Proxy authored as scene node: %s" % proxy)

func _process(_delta: float) -> void:
	frames += 1
	if frames >= TEST_FRAMES:
		run_assertions()
		get_tree().quit(exit_code)

func run_assertions() -> void:
	var passes := 0
	var fails := 0
	print("\n=== Smoke Test Results (after %d frames) ===" % frames)

	var src_skel := source.get_skeleton()
	var src_slots := src_skel.get_slots()
	var split_index := -1
	for slot in src_slots:
		if slot.get_data().get_name() == SPLIT_SLOT:
			split_index = slot.get_data().get_index()
			break
	if split_index < 0:
		print("FAIL: split slot '%s' not found" % SPLIT_SLOT)
		_report(0, 1); return
	print("Split: slot '%s' (index %d). Source keeps [0, %d), proxy keeps [%d, %d)." \
		% [SPLIT_SLOT, split_index, split_index, split_index, src_slots.size()])

	var prx_skel := proxy.get_skeleton()
	var prx_slots := prx_skel.get_slots()

	# 1) Bone mirror.
	var src_bones := src_skel.get_bones()
	var prx_bones := prx_skel.get_bones()
	var bone_diff_count := 0
	var max_diff := 0.0
	for i in src_bones.size():
		var a = src_bones[i].get_pose()
		var b = prx_bones[i].get_pose()
		var d: float = max(abs(a.get_x() - b.get_x()),
			max(abs(a.get_y() - b.get_y()),
			max(abs(a.get_rotation() - b.get_rotation()),
			max(abs(a.get_scale_x() - b.get_scale_x()),
				abs(a.get_scale_y() - b.get_scale_y())))))
		max_diff = max(max_diff, d)
		if d > 0.001:
			bone_diff_count += 1
	if bone_diff_count == 0:
		print("[PASS] BONE_MIRROR        — %d/%d bones match (max diff %.6f)" \
			% [src_bones.size(), src_bones.size(), max_diff])
		passes += 1
	else:
		print("[FAIL] BONE_MIRROR        — %d/%d bones mismatched (max diff %.6f)" \
			% [bone_diff_count, src_bones.size(), max_diff])
		fails += 1

	# 2) Attachment mirror. Compare by name because get_attachment() may
	# return fresh wrapper Refs each call (so direct ref equality is unreliable).
	var attach_diff_count := 0
	var attach_problems: Array = []
	for i in src_slots.size():
		var sa = src_slots[i].get_pose().get_attachment()
		var pa = prx_slots[i].get_pose().get_attachment()
		var sn: String = sa.get_attachment_name() if sa != null else ""
		var pn: String = pa.get_attachment_name() if pa != null else ""
		var sn_null: bool = (sa == null)
		var pn_null: bool = (pa == null)
		if sn_null != pn_null or sn != pn:
			attach_diff_count += 1
			if attach_problems.size() < 5:
				attach_problems.append("  slot %d (%s): source='%s' proxy='%s'" \
					% [i, src_slots[i].get_data().get_name(),
					   "<null>" if sn_null else sn,
					   "<null>" if pn_null else pn])
	if attach_diff_count == 0:
		print("[PASS] ATTACHMENT_MIRROR  — %d/%d slots match" % [src_slots.size(), src_slots.size()])
		passes += 1
	else:
		print("[FAIL] ATTACHMENT_MIRROR  — %d/%d slots mismatched" % [attach_diff_count, src_slots.size()])
		for p in attach_problems: print(p)
		fails += 1

	# 3) Source mask: slots [split, end) should be α=0; [0, split) should be α≈1.
	var src_problems: Array = []
	for i in src_slots.size():
		var alpha: float = src_slots[i].get_pose().get_color().a
		var should_be_zero: bool = (i >= split_index)
		if should_be_zero and alpha > 0.001:
			src_problems.append("  slot %d (%s) expected α=0, got α=%.3f" \
				% [i, src_slots[i].get_data().get_name(), alpha])
		elif not should_be_zero and alpha < 0.999:
			src_problems.append("  slot %d (%s) expected α=1, got α=%.3f" \
				% [i, src_slots[i].get_data().get_name(), alpha])
	if src_problems.is_empty():
		print("[PASS] SOURCE_MASK        — hides [%d, %d), shows [0, %d)" \
			% [split_index, src_slots.size(), split_index])
		passes += 1
	else:
		print("[FAIL] SOURCE_MASK")
		for p in src_problems: print(p)
		fails += 1

	# 4) Proxy mask: [0, split) should be α=0; [split, end) should mirror source's
	# restored-then-applied α. We compare proxy's α against the slot's setup-pose
	# α — they should match for any slot the walk anim doesn't have a color
	# timeline for. Some slots (e.g. "muzzle-glow") have setup α=0 by design.
	var prx_zero_problems: Array = []
	var prx_nonzero_problems: Array = []
	for i in prx_slots.size():
		var alpha: float = prx_slots[i].get_pose().get_color().a
		var setup_alpha: float = prx_slots[i].get_data().get_color().a
		var name: String = prx_slots[i].get_data().get_name()
		if i < split_index:
			if alpha > 0.001:
				prx_zero_problems.append("  slot %d (%s) expected α=0, got α=%.3f" % [i, name, alpha])
		else:
			# Only flag if the setup pose has α>0 (so we expect a non-zero mirror)
			# but the proxy ended up zeroed.
			if setup_alpha > 0.001 and alpha < 0.001:
				prx_nonzero_problems.append("  slot %d (%s) expected α>0 (setup α=%.3f), got α=%.3f" \
					% [i, name, setup_alpha, alpha])
	if prx_zero_problems.is_empty() and prx_nonzero_problems.is_empty():
		print("[PASS] PROXY_MASK         — hides [0, %d), shows [%d, %d)" \
			% [split_index, split_index, prx_slots.size()])
		passes += 1
	else:
		print("[FAIL] PROXY_MASK")
		for p in prx_zero_problems: print(p)
		for p in prx_nonzero_problems: print(p)
		fails += 1

	_report(passes, fails)

func _report(passes: int, fails: int) -> void:
	print("\n=== %d/%d PASSED ===" % [passes, passes + fails])
	if fails > 0:
		exit_code = 1
