class_name MqttLastWill extends Resource

## Decides if the last will message should be sent to people that connect in the future
@export var retain := false
## The QOS type to use for the last will message
@export var qos := MqttNode.Qos.AT_MOST_ONCE
## The topic to where to send the last will message
@export var topic := ""
## The message (string) that should be sent
@export var msg_string := ""
## The message (bytes) that should be sent
@export var msg_buffer := PackedByteArray()
