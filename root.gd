extends Node2D

func _update_label(text: String, print_text:=true) -> void:
	$StatusLabel.text = text
	if print_text:
		print(text)

func _on_mqtt_node_connected(reconnection: bool) -> void:
	_update_label("Connected%s!" % (" (reconnect)" if reconnection else ""))

func _on_mqtt_node_connecting() -> void:
	_update_label("Connecting...")

func _on_mqtt_node_disconnected(reason: String) -> void:
	_update_label("Disconnected: %s" % reason)

func _on_mqtt_node_connecting_failed() -> void:
	_update_label("Connecting failed!")

func _on_mqtt_node_reconnecting(attempt: int, delay: float) -> void:
	_update_label("Reconnect #%d in %.1fs" % [attempt, delay])

func _on_mqtt_node_error(msg: String) -> void:
	push_error(msg)
	$StatusLabel.text = "Error: %s" % msg

func _on_mqtt_node_message(topic: String, payload: PackedByteArray, retained: bool) -> void:
	_update_label("Message (%s, retained=%s): %d bytes" % [topic, retained, payload.size()])

func _on_mqtt_node_ping(ms: int) -> void:
	$PingLabel.text = "Ping: %sms" % ms
