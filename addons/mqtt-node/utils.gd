const Constants := preload("./constants.gd")

static func get_user_agent() -> String:
	return "%s/%s (%s) Godot/%s" % [
		Constants.NAME,
		Constants.VERSION,
		OS.get_name(),
		Engine.get_version_info()["string"]
	]
