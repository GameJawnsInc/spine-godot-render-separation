@tool
extends Node2D

# Render-separation demo: a raptor walks between the back and front halves of
# a spineboy.
#
# Layering:
#   - Spineboy (source) has z_index = -1 → its visible slots (back half) draw
#     behind the raptor.
#   - Raptor has z_index = 0 → draws between spineboy's halves.
#   - FrontProxy (SpineSpriteProxy, authored in the scene) has z_index = 1 →
#     renders spineboy's front-half slots above the raptor.
#
# The proxy follows the source's global transform (default), so wherever you
# move the spineboy, the proxy's rendering stays aligned.

@onready var raptor: SpineSprite = %Raptor
@onready var spineboy: SpineSprite = %Spineboy


func _ready() -> void:
	# At runtime, drive the animations explicitly. In the editor, the SpineSprite
	# preview_animation properties already drive playback — don't double-drive.
	if not Engine.is_editor_hint():
		raptor.get_animation_state().set_animation("walk", true, 0)
		spineboy.get_animation_state().set_animation("walk", true, 0)
