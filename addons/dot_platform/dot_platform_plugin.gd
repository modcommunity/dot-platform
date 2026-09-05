@tool
extends EditorPlugin

## Editor entry point for dot-platform. Registers inspector types only.
##
## No autoload, for the family's reason: a process may run a server and a client at
## once — which is exactly what this project's own listen-server example does — and a
## singleton platform would make that impossible.

const _ICON := "res://addons/dot_platform/icon_placeholder.svg"

const _TYPES := [
	["DotPlatformHub", "Node", "res://addons/dot_platform/dot_platform.gd"],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
