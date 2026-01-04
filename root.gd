extends Node2D

func _on_mqtt_node_connected() -> void:
	$StatusLabel.text = "Connected!"

func _on_mqtt_node_connecting() -> void:
	$StatusLabel.text = "Connecting..."

func _on_mqtt_node_disconnected() -> void:
	$StatusLabel.text = "Disconnected!"

func _on_mqtt_node_connecting_failed() -> void:
	$StatusLabel.text = "Connecting failed!"

func _on_mqtt_node_error(msg: String) -> void:
	push_error(msg)
	$StatusLabel.text = "Error: %s" % msg  

func _on_mqtt_node_message(topic: String, msg: PackedByteArray) -> void:
	pass # Replace with function body.

func _on_mqtt_node_ping(ms: int) -> void:
	$PingLabel.text = "Ping: %sms" % ms

func _on_ping_timer_timeout() -> void:
	if $MqttNode.connection_established:
		$MqttNode.send_ping()
