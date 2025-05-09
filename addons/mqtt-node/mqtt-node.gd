class_name MqttNode extends Node
const PacketStream := preload("./packet-stream.gd")

#region enums
enum PacketType {
	NONE		= 0b0000,
	CONNECT		= 0b0001,
	CONNACK		= 0b0010,
	PUBLISH		= 0b0011,
	PUBACK		= 0b0100,
	PUBREC		= 0b0101,
	PUBREL		= 0b0110,
	PUBCOMP		= 0b0111,
	SUBSCRIBE	= 0b1000,
	SUBACK		= 0b1001,
	UNSUBSCRIBE	= 0b1010,
	UNSUBACK	= 0b1011,
	PINGREQ		= 0b1100,
	PINGRESP	= 0b1101,
	DISCONNECT	= 0b1110,
	AUTH		= 0b1111 # MQTT 5.0 only
}

enum PacketFlag {
	NONE	= 0b0000,
	RETAIN	= 0b0001,
	QOS1	= 0b0010,
	QOS2	= 0b0100,
	DUP		= 0b1000,
}

enum Qos {
	AT_MOST_ONCE,	# QoS 0 - Best effort, no acknowledgment
	AT_LEAST_ONCE,	# QoS 1 - Guaranteed delivery, may be duplicated
	EXACTLY_ONCE	# QoS 2 - Guaranteed *once* delivery, no duplicates
}

enum ConnectFlags {
	CLEAN_SESSION		= 0x02,
	LAST_WILL			= 0x04,
	LAST_WILL_QOS_1		= 0x08,
	LAST_WILL_QOS_2		= 0x10,
	LAST_WILL_RETAIN	= 0x20,
	PASS				= 0x40,
	USER				= 0x80
}

#endregion

#region signals
signal connecting()
signal connecting_failed()
signal connected()
signal disconnected()
signal subscribed(topic: String, qos: Qos)
signal unsubscribed(topic: String)
signal message(topic: String, msg: PackedByteArray)
signal ping(ms: int)
signal error(msg: String)
#endregion

#region exports
@export var broker := "wss://broker.hivemq.com:8884/mqtt"
@export var clean_session := true
@export_range(0, 120) var keep_alive := 60
@export var last_will: MqttLastWill
@export var client_id := ""
@export var username := ""
@export var password := ""
@export var auto_connect := true
#endregion

var socket: WebSocketPeer
var connection_established := false
var recv_stream := PacketStream.new()
var last_ping_time := 0.0
var current_ping := -1
var subscriptions := {}
var packet_ack_queue := {} # We put packets with their id here to have context
var connection_state := WebSocketPeer.STATE_CLOSED

func _ready() -> void:
	if client_id == "":
		randomize()
		client_id = "rr%d" % randi()
	if auto_connect:
		connect_to_broker()

func connect_to_broker() -> Error:
	if socket:
		_error("Socket already in use")
		return ERR_ALREADY_IN_USE

	socket = WebSocketPeer.new()
	socket.supported_protocols = PackedStringArray(["mqttv3.1"])
	socket.inbound_buffer_size = 1024 * 1024

	if OS.get_name() != "Web":
		socket.handshake_headers = PackedStringArray(["User-Agent: GodotMQTT"])

	var err := socket.connect_to_url(broker)
	if err != OK:
		socket = null
		_error("Failed to open websocket: %s" % err)
		return err

	connecting.emit()
	return OK

func disconnect_from_broker() -> Error:
	if not socket:
		_error("No socket for disconnect")
		return ERR_DOES_NOT_EXIST

	socket.close()
	return OK

func publish(topic: String, msg: PackedByteArray, qos: Qos = Qos.AT_MOST_ONCE, retain: bool = false) -> Error:
	if not socket or not connection_established:
		_error("Socket not connected for publish")
		return ERR_CONNECTION_ERROR

	var flags: int = PacketFlag.NONE
	if retain:
		flags |= PacketFlag.RETAIN
	if qos == Qos.AT_LEAST_ONCE:
		flags |= PacketFlag.QOS1
	elif qos == Qos.EXACTLY_ONCE:
		flags |= PacketFlag.QOS2

	var stream := PacketStream.new()
	stream.put_prefixed_utf8_string(topic)

	if qos != Qos.AT_MOST_ONCE:
		var packet_id := _gen_packet_id()
		packet_ack_queue[packet_id] = { type=PacketType.PUBLISH, flags=flags, id=packet_id, topic=topic, msg=msg }
		stream.put_u16(packet_id)

	stream.put_data(msg)

	return _send_packet(PacketType.PUBLISH, flags, stream.data_array)

func subscribe(topic: String, qos: Qos = Qos.AT_MOST_ONCE) -> Error:
	return subscribe_many([{ topic=topic, qos=qos }])

func subscribe_many(items: Array[Dictionary]) -> Error:
	if not connection_established:
		_error("Socket not connected for subscribe")
		return ERR_CONNECTION_ERROR

	var packet_id := _gen_packet_id()
	packet_ack_queue[packet_id] = {
		type=PacketType.SUBSCRIBE,
		flags=PacketFlag.QOS1,
		items=items
	}

	var stream := PacketStream.new()
	stream.put_u16(packet_id)

	for item in items:
		stream.put_prefixed_utf8_string(item.topic)
		stream.put_u8(item.qos)

	return _send_packet(PacketType.SUBSCRIBE, PacketFlag.QOS1, stream.data_array)

func unsubscribe(topic: String) -> Error:
	return unsubscribe_many([topic])

func unsubscribe_many(topics: Array[String]) -> Error:
	if not connection_established:
		_error("Socket not connected for unsubscribe")
		return ERR_CONNECTION_ERROR

	var packet_id := _gen_packet_id()
	packet_ack_queue[packet_id] = { type=PacketType.UNSUBSCRIBE, flags=PacketFlag.QOS1, topics=topics }

	var stream := PacketStream.new()
	stream.put_u16(packet_id)

	for topic in topics:
		stream.put_prefixed_utf8_string(topic)

	return _send_packet(PacketType.UNSUBSCRIBE, PacketFlag.QOS1, stream.data_array)

# Lifecycle
func _process(_delta: float) -> void:
	if not socket:
		return

	socket.poll()
	var ready_state := socket.get_ready_state()

	if connection_state != ready_state:
		_on_connection_state_changed(ready_state, connection_state)
		connection_state = ready_state

	# Just handle connected state
	if ready_state != WebSocketPeer.STATE_OPEN:
		return

	# Read buffer
	while socket.get_available_packet_count():
		recv_stream.append_data(socket.get_packet())

	# Handle packets
	while recv_stream.bytes_left > 1:
		var packet = _read_packet()
		if packet == null:
			break
		_on_packet(packet.type, packet.flags, packet.payload)

	# Handle keepalive
	if connection_established:
		if keep_alive > 0:
			var current_time := Time.get_unix_time_from_system()
			var time_diff := current_time - last_ping_time
			if time_diff > keep_alive:
				last_ping_time = current_time
				_send_ping()

# Internal functions
func _send_packet(control_type: PacketType, control_flag: PacketFlag, payload:=PackedByteArray()) -> Error:
	if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_error("Socket not connected")
		return ERR_CONNECTION_ERROR
		
	var buffer := _create_packet_buffer(control_type, control_flag, payload)
	socket.send(buffer)
	return OK

func _send_connect() -> Error:
	if connection_established:
		_error("Already connected")
		return ERR_CONNECTION_ERROR

	# Prepare flags
	var connect_flags := 0
	if clean_session:
		connect_flags |= ConnectFlags.CLEAN_SESSION
	if last_will:
		connect_flags |= ConnectFlags.LAST_WILL
		if last_will.retain:
			connect_flags |= ConnectFlags.LAST_WILL_RETAIN
		if last_will.qos == Qos.AT_LEAST_ONCE:
			connect_flags |= ConnectFlags.LAST_WILL_QOS_1
		elif last_will.qos == Qos.EXACTLY_ONCE:
			connect_flags |= ConnectFlags.LAST_WILL_QOS_2
	if username:
		connect_flags |= ConnectFlags.USER
		if password:
			connect_flags |= ConnectFlags.PASS

	# Sanity check keep_alive
	if keep_alive < 0 or keep_alive > 0xFFFF:
		_error("Invalid keep_alive: %s" % keep_alive)
		keep_alive = 60

	# Create payload
	var stream := PacketStream.new()
	stream.put_prefixed_utf8_string("MQTT")
	stream.put_u8(4) # Protocol Level = 4 -> 3.1.X  / 5 -> 5
	stream.put_u8(connect_flags)
	stream.put_u16(keep_alive)
	stream.put_prefixed_utf8_string(client_id)

	if last_will:
		stream.put_prefixed_utf8_string(last_will.topic)
		if last_will.msg_string:
			stream.put_prefixed_utf8_string(last_will.msg_string)
		else:
			stream.put_prefixed_data(last_will.msg_buffer)

	if username:
		stream.put_prefixed_utf8_string(username)
		if password:
			stream.put_prefixed_utf8_string(password)

	return _send_packet(PacketType.CONNECT, PacketFlag.NONE, stream.data_array)

func _send_ping() -> Error:
	if not connection_established:
		_error("Socket not connected for ping")
		return ERR_CONNECTION_ERROR

	return _send_packet(PacketType.PINGREQ, PacketFlag.NONE)

func _send_disconnect() -> Error:
	if not connection_established:
		_error("Socket not connected for disconnect")
		return ERR_CONNECTION_ERROR

	return _send_packet(PacketType.DISCONNECT, PacketFlag.NONE)
		
func _create_packet_buffer(control_type: PacketType, control_flag: PacketFlag, payload:=PackedByteArray()) -> PackedByteArray:
	var stream := PacketStream.new()
	stream.put_u8((control_type << 4) | (control_flag & 0xF))
	stream.put_dynamic_prefixed_data(payload)
	return stream.data_array

func _read_packet() -> Variant:
	var position := recv_stream.get_position()
	var control_byte := recv_stream.get_u8()
	var type := control_byte >> 4 as PacketType
	var flags := control_byte & 0xF as PacketFlag
	var payload = recv_stream.get_dynamic_prefixed_data()
	if payload == null:
		recv_stream.seek(position)
		return null
	recv_stream.remove_tail()
	return { type=type, flags=flags, payload=payload }

func _reset() -> void:
	connection_established = false
	connection_state = WebSocketPeer.STATE_CLOSED
	current_ping = -1
	recv_stream.clear()
	packet_ack_queue = {}
	subscriptions = {}
	last_ping_time = 0.0

func _error(text: String) -> void:
	error.emit(text)
	push_error(text)

func _gen_packet_id() -> int:
	while true:
		var id := (randi() % 65535) + 1
		if not id in packet_ack_queue:
			return id
	return 0

# Internal callbacks
func _on_connection_state_changed(new_state: WebSocketPeer.State, _old_state: WebSocketPeer.State) -> void:
	if new_state == WebSocketPeer.STATE_OPEN:
		_send_connect()

	if new_state == WebSocketPeer.STATE_CLOSED:
		var was_connected := connection_established
		_reset()
		if was_connected:
			disconnected.emit()
		else:
			connecting_failed.emit()

func _on_packet(type: PacketType, flags: PacketFlag, payload: PackedByteArray) -> void:
	if type == PacketType.CONNACK:
		return _on_packet_connack(payload)

	if type == PacketType.SUBACK:
		return _on_packet_suback(payload)

	if type == PacketType.UNSUBACK:
		return _on_packet_unsuback(payload)

	if type == PacketType.PUBLISH:
		return _on_packet_publish(payload, flags)

	if type == PacketType.PUBACK:
		return _on_packet_puback(payload)

	if type == PacketType.PUBREC:
		return _on_packet_pubrec(payload)

	if type == PacketType.PUBCOMP:
		return _on_packet_pubcomp(payload)

	if type == PacketType.PINGRESP:
		return _on_packet_pingresp(payload)

	if type == PacketType.DISCONNECT:
		return socket.close()

	_error("Unhandled packet: type=%s, flags=%s, payload=%s" % [
		PacketType.find_key(type),
		flags,
		payload
	])

func _on_packet_connack(payload: PackedByteArray) -> void:
	# MQTT 3.1.1: payload[0] is connect ack flags, payload[1] is return code
	# For a successful connection, return code = 0
	if payload.size() < 2:
		_error("Invalid CONNACK received")
		disconnect_from_broker()
		return

	var return_code := payload[1]
	if return_code != 0:
		_error("CONNACK error code: %d" % return_code)
		disconnect_from_broker()
		return

	connection_established = true
	connected.emit()

func _on_packet_suback(payload: PackedByteArray) -> void:
	var stream := PacketStream.new(payload)
	var packet_id := stream.get_u16()
	if not packet_id in packet_ack_queue:
		_error("Unknown packet id in suback: %s" % packet_id)
		return

	var packet = packet_ack_queue[packet_id]
	packet_ack_queue.erase(packet_id)

	for item in packet.items:
		var qos = stream.get_u8()
		if qos == 0x80:
			_error("Failed subscribing to %s" % item.topic)
		else:
			subscriptions[item.topic] = { topic=item.topic, qos=qos }
			subscribed.emit(item.topic, qos)

func _on_packet_unsuback(payload: PackedByteArray) -> void:
	var stream := PacketStream.new(payload)
	var packet_id := stream.get_u16()
	if not packet_id in packet_ack_queue:
		_error("Unknown packet id in unsuback: %s" % packet_id)
		return

	var packet = packet_ack_queue[packet_id]
	packet_ack_queue.erase(packet_id)

	for topic in packet.topics:
		subscriptions.erase(topic)
		unsubscribed.emit(topic)

func _on_packet_publish(payload: PackedByteArray, flags: PacketFlag) -> void:
	var stream := PacketStream.new(payload)
	var topic := stream.get_prefixed_utf8_string()

	var qos := 0
	if flags & PacketFlag.QOS1:
		qos = 1
	elif flags & PacketFlag.QOS2:
		qos = 2

	var packet_id := 0
	if qos > 0:
		packet_id = stream.get_u16()

	var msg = stream.get_rest_data()

	message.emit(topic, msg)
	if qos == Qos.AT_MOST_ONCE:
		return

	# Respond if QoS > 0
	stream.clear()
	stream.put_u16(packet_id)

	if qos == Qos.AT_LEAST_ONCE:
		_send_packet(PacketType.PUBACK, PacketFlag.NONE, stream.data_array)
	elif qos == Qos.EXACTLY_ONCE:
		# PUBREC -> then wait PUBREL -> then PUBCOMP
		_send_packet(PacketType.PUBREC, PacketFlag.NONE, stream.data_array)

func _on_packet_puback(payload: PackedByteArray) -> void:
	var stream := PacketStream.new(payload)
	var packet_id := stream.get_u16()
	if not packet_id in packet_ack_queue:
		_error("Unknown packet id in puback: %s" % packet_id)
		return

	packet_ack_queue.erase(packet_id)
	# Our publish was acknowledged

func _on_packet_pubrec(payload: PackedByteArray) -> void:
	var stream := PacketStream.new(payload)
	var packet_id := stream.get_u16()
	if not packet_id in packet_ack_queue:
		_error("Unknown packet id in pubrec: %s" % packet_id)
		return

	_send_packet(PacketType.PUBREL, PacketFlag.QOS1, payload)

func _on_packet_pubcomp(payload: PackedByteArray) -> void:
	var stream := PacketStream.new(payload)
	var packet_id := stream.get_u16()
	if not packet_id in packet_ack_queue:
		_error("Unknown packet id in pubcomp: %s" % packet_id)
		return

	packet_ack_queue.erase(packet_id)
	# Our publish was acknowledged

func _on_packet_pingresp(_payload) -> void:
	current_ping = int((Time.get_unix_time_from_system() - last_ping_time) * 1000 / 2)
	ping.emit(current_ping)
