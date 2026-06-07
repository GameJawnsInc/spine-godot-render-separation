extends Node2D

# Automated smoke test for SpineSpriteProxy. Authors a 2-way split, ticks for
# a few frames, then asserts:
#   1. BONE_MIRROR        — every proxy bone's local pose matches source's.
#   2. ATTACHMENT_MIRROR  — every proxy slot's attachment matches source's
#                            (verifies attachment refs are valid across skeletons).
#   3. SOURCE_MASK        — slots in the proxy's draw-order claim are hidden
#                            on the source; slots outside the claim are not.
#   4. PROXY_MASK         — slots in the claim are visible on the proxy;
#                            slots outside the claim are hidden.
#
# The "claim" is computed the same way the proxy computes it: from the source's
# CURRENT draw order, the slot at SPLIT_SLOT's draw position through the end of
# draw order. With a draw-order-animating skeleton this set differs from a
# raw slot-index range.
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
	var src_draw_order := src_skel.get_draw_order()

	# Compute the proxy's expected claim using the same draw-order logic the
	# proxy uses: slots at draw-order positions [pos_of(SPLIT_SLOT), end).
	var split_draw_pos := -1
	for i in src_draw_order.size():
		if src_draw_order[i].get_data().get_name() == SPLIT_SLOT:
			split_draw_pos = i
			break
	if split_draw_pos < 0:
		print("FAIL: split slot '%s' not found in draw order" % SPLIT_SLOT)
		_report(0, 1); return
	var claimed: Dictionary = {}
	for i in range(split_draw_pos, src_draw_order.size()):
		claimed[src_draw_order[i].get_data().get_index()] = true
	print("Split slot '%s' at draw position %d of %d. Claim covers %d slot indices." \
		% [SPLIT_SLOT, split_draw_pos, src_draw_order.size(), claimed.size()])

	var prx_skel := proxy.get_skeleton()
	var prx_slots := prx_skel.get_slots()

	# 1) Bone mirror — applied_pose world transforms, since that's what the
	# renderer actually reads (RegionAttachment.cpp:68 / VertexAttachment.cpp:62).
	# For constrained bones (every IK chain — legs, arms) applied_pose points
	# at _constrainedPose, which is a different object than get_pose().
	var src_bones := src_skel.get_bones()
	var prx_bones := prx_skel.get_bones()
	var bone_diff_count := 0
	var max_world_diff := 0.0
	var problems_shown: int = 0
	for i in src_bones.size():
		var a = src_bones[i].get_applied_pose()
		var b = prx_bones[i].get_applied_pose()
		var d: float = max(abs(a.get_a() - b.get_a()),
			max(abs(a.get_b() - b.get_b()),
			max(abs(a.get_c() - b.get_c()),
			max(abs(a.get_d() - b.get_d()),
			max(abs(a.get_world_x() - b.get_world_x()),
				abs(a.get_world_y() - b.get_world_y()))))))
		max_world_diff = max(max_world_diff, d)
		if d > 0.001:
			bone_diff_count += 1
			if problems_shown < 5:
				print("  bone %d (%s): src a/b/c/d/wx/wy = %.3f/%.3f/%.3f/%.3f/%.3f/%.3f" \
					% [i, src_bones[i].get_data().get_bone_name(),
					   a.get_a(), a.get_b(), a.get_c(), a.get_d(), a.get_world_x(), a.get_world_y()])
				print("              prx a/b/c/d/wx/wy = %.3f/%.3f/%.3f/%.3f/%.3f/%.3f" \
					% [b.get_a(), b.get_b(), b.get_c(), b.get_d(), b.get_world_x(), b.get_world_y()])
				problems_shown += 1
	if bone_diff_count == 0:
		print("[PASS] BONE_MIRROR        — %d/%d applied_pose world transforms match (max diff %.6f)" \
			% [src_bones.size(), src_bones.size(), max_world_diff])
		passes += 1
	else:
		print("[FAIL] BONE_MIRROR        — %d/%d applied_pose world transforms mismatched (max diff %.6f)" \
			% [bone_diff_count, src_bones.size(), max_world_diff])
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

	# 3) Source mask: claimed slot indices should be α=0; unclaimed slots
	# should retain whatever α the animation set them to (we only flag the
	# unclaimed case when the setup α is non-zero — slots with setup α=0
	# stay invisible regardless).
	var src_problems: Array = []
	for i in src_slots.size():
		var alpha: float = src_slots[i].get_pose().get_color().a
		var setup_alpha: float = src_slots[i].get_data().get_color().a
		var name: String = src_slots[i].get_data().get_name()
		if claimed.has(i):
			if alpha > 0.001:
				src_problems.append("  slot %d (%s) claimed → expected α=0, got α=%.3f" \
					% [i, name, alpha])
		else:
			if setup_alpha > 0.001 and alpha < 0.001:
				src_problems.append("  slot %d (%s) unclaimed → expected α>0 (setup α=%.3f), got α=%.3f" \
					% [i, name, setup_alpha, alpha])
	if src_problems.is_empty():
		print("[PASS] SOURCE_MASK        — %d claimed slots hidden, %d unclaimed untouched" \
			% [claimed.size(), src_slots.size() - claimed.size()])
		passes += 1
	else:
		print("[FAIL] SOURCE_MASK")
		for p in src_problems: print(p)
		fails += 1

	# 4) Proxy mask: claimed slot indices should be visible (mirror copied
	# the source's pre-mask α, which equals setup α for slots without color
	# timelines); unclaimed slot indices should be α=0.
	var prx_problems: Array = []
	for i in prx_slots.size():
		var alpha: float = prx_slots[i].get_pose().get_color().a
		var setup_alpha: float = prx_slots[i].get_data().get_color().a
		var name: String = prx_slots[i].get_data().get_name()
		if claimed.has(i):
			if setup_alpha > 0.001 and alpha < 0.001:
				prx_problems.append("  slot %d (%s) claimed → expected α>0 (setup α=%.3f), got α=%.3f" \
					% [i, name, setup_alpha, alpha])
		else:
			if alpha > 0.001:
				prx_problems.append("  slot %d (%s) unclaimed → expected α=0, got α=%.3f" \
					% [i, name, alpha])
	if prx_problems.is_empty():
		print("[PASS] PROXY_MASK         — %d claimed slots shown, %d unclaimed hidden" \
			% [claimed.size(), prx_slots.size() - claimed.size()])
		passes += 1
	else:
		print("[FAIL] PROXY_MASK")
		for p in prx_problems: print(p)
		fails += 1

	_report(passes, fails)

func _report(passes: int, fails: int) -> void:
	print("\n=== %d/%d PASSED ===" % [passes, passes + fails])
	if fails > 0:
		exit_code = 1
