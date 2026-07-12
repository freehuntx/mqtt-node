class_name MqttLastWill extends Resource

## @deprecated Kept only for backwards-compatibility of scenes saved with the
## old resource-based will. Prefer the flat will_* properties on MqttNode,
## which hold a binary payload directly. This resource is still read by
## MqttNode when assigned, so existing scenes keep working.

## Decides if the last will message should be sent to people that connect in the future
@export var retain := false
## The QOS type to use for the last will message
@export var qos := 0
## The topic to where to send the last will message
@export var topic := ""
## The message (string) that should be sent
@export var msg_string := ""
## The message (bytes) that should be sent
@export var msg_buffer := PackedByteArray()
