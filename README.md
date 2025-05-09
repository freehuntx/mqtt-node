# mqtt-node
<p align="center">
  <img src="logo.png" alt="Logo" width="200"/>
</p>

## Overview
A simple mqtt (v3) implementation in gdscript.  

For cross-platform compatibility its just working with websocket. There are no plans to support tcp/udp!  

## Installation
1. Copy `addons/mqtt-node` to your godot project
2. Done! You can use the MqttNode component now!

## Usage
### Example (Using just code)
```
extends Node2D

@onready var mqtt := MqttNode.new()

func _ready() -> void:
	mqtt.broker = 'wss://broker.hivemq.com:8884/mqtt'
	mqtt.auto_connect = true

	mqtt.connecting.connect(func():
		print("Connecting...")
	)
	mqtt.connecting_failed.connect(func():
		print("Connecting failed!")
	)
	mqtt.connected.connect(func():
		print("Connected!")
		mqtt.subscribe("test/#")
	)
	mqtt.disconnected.connect(func():
		print("Disonnected!")
	)
	mqtt.message.connect(func(topic, msg):
		print("Message (%s): %s" % [topic, msg])
	)
	add_child(mqtt)
```

