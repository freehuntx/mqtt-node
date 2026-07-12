class_name MqttNode extends Node
const PacketStream := preload("./packet-stream.gd")
const Utils := preload("./utils.gd")
# Preloaded (not relying on the global class_name cache) so the script compiles
# headless without a prior `--import`. lastwill.gd also declares
# `class_name MqttLastWill`; this const is the same script under a local name.
const LastWillClass := preload("./lastwill.gd")

const FREE_BROKERS = [
	"wss://broker.hivemq.com:8884/mqtt",
	"wss://test.mosquitto.org:8081",
	"wss://broker.emqx.io:8084/mqtt",
]

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

## Internal connection state machine.
enum State {
	IDLE,
	CONNECTING,
	CONNECTED,
	RECONNECT_WAIT,
	DISCONNECTING,
}

#endregion

#region signals
## Emitted after CONNACK success and all registered subscriptions have been
## re-sent. `reconnection` is false on the first successful connect and true
## on every auto-reconnect thereafter.
signal connected(reconnection: bool)
## Emitted when the transport was open but is now closed. `reason` is a
## short human-readable string.
signal disconnected(reason: String)
## Emitted before each reconnect attempt (after the backoff delay has been
## scheduled). `attempt` is the 1-based attempt counter, `delay` the seconds
## that will elapse before the next connect.
signal reconnecting(attempt: int, delay: float)
## Emitted when the socket is being opened for the first time (not on
## reconnects — use `reconnecting` for those).
signal connecting()
## Emitted when the initial (non-reconnect) connect attempt fails.
signal connecting_failed()
## Emitted on SUBACK, once per topic filter.
signal subscribed(topic: String, qos: int)
## Emitted on UNSUBACK, once per topic filter.
signal unsubscribed(topic: String)
## Emitted on incoming PUBLISH. `payload` is the raw bytes; `retained`
## reflects the RETAIN bit of the received PUBLISH fixed header.
signal message(topic: String, payload: PackedByteArray, retained: bool)
## Emitted on a successful PINGREQ/PINGRESP round trip (full RTT, in ms).
signal ping(ms: int)
## Generic error channel (bad packets, CONNACK codes, publish failures...).
signal error(message: String)
#endregion

#region exports
## Broker WebSocket URL, e.g. `wss://broker.hivemq.com:8884/mqtt`.
@export var broker := FREE_BROKERS[0]
## Always true in this release; persistent sessions interact badly with
## auto-resubscription. Exposed but ignored if set to false.
@export var clean_session := true
## Keep-alive interval in seconds, sent in CONNECT. 0 disables pings.
@export_range(0, 65535) var keep_alive := 30
## Client ID. Leave empty to auto-generate a cryptographically random ID
## (20 chars from [0-9a-zA-Z]) on every connect. If you set this, the same
## ID is reused across reconnects.
@export var client_id := ""
## MQTT username (optional). Leave empty for anonymous.
@export var username := ""
## MQTT password (optional). Leave empty for no password.
@export var password := ""
## If true, the node connects on _ready.
@export var auto_connect := true

# --- Last Will & Testament -------------------------------------------------
## Will topic. Empty string means "no will". Applied at CONNECT time only;
## changing it while connected has no effect until the next (re)connect.
@export var will_topic: String = ""
## Will RETAIN flag.
@export var will_retain: bool = false
## Will QoS (0-2).
@export var will_qos: int = 0
## Will payload as raw bytes. Not exported in the inspector as a String to
## avoid UTF-8 corruption of binary data. Set from code.
var will_payload: PackedByteArray = PackedByteArray()
## @deprecated Old resource-based will. Still read when assigned (for scenes
## saved with the previous API); the flat will_* properties above take
## precedence when set.
@export var last_will: LastWillClass

# --- Auto-reconnect --------------------------------------------------------
@export var auto_reconnect: bool = true
@export var reconnect_min_delay: float = 1.0
@export var reconnect_max_delay: float = 30.0

# --- Robust parsing / queue -----------------------------------------------
## Packets whose Remaining Length exceeds this are a protocol error:
## the connection is dropped (desynced streams cannot be resynchronized).
@export var max_packet_size: int = 262144
## Bounded outgoing queue while disconnected. 0 = fail-fast (default).
## When > 0, publishes are buffered and flushed after reconnect, dropping
## the oldest on overflow.
@export var offline_queue_size: int = 0
#endregion
#endregion

#region state
var socket: WebSocketPeer
var connection_established := false
var recv_stream := PacketStream.new()
var last_packet_sent_time := 0.0
var last_packet_received_time := 0.0
var last_ping_time := 0.0
var current_ping := -1
var _last_packet_id := 0
var _connection_state: State = State.IDLE
var _was_connected := false
var _reconnect_attempt := 0
var _reconnect_at := 0.0
var _connected_at := 0.0
var _last_session_survived := 0.0
var _user_client_id := false
var _resubscribe_pending := false
var _connect_sent := false
# Wall-clock time the CONNECT packet was sent; used to detect a broker that
# accepts the WebSocket but never replies at the MQTT layer.
var _connect_sent_at := 0.0
# When non-empty, the connection is being torn down due to a protocol/keepalive
# error; _on_socket_closed consumes this as the disconnect reason. Set by
# _fail_connection to avoid double reset/emit/schedule.
var _pending_fail_reason := ""
# Set when a non-retryable CONNACK code (1, 2, 4, 5) is received; suppresses
# auto-reconnect until the user explicitly calls connect_to_broker() again
# (e.g. after fixing credentials). Does not mutate the user-facing
# auto_reconnect property.
var _reconnect_suppressed := false

# Subscription registry: topic filter (String) -> desired qos (int)
var subscriptions := {}
# Pending outgoing SUBSCRIBE/UNSUBSCRIBE waiting for their ack, keyed by
# packet id. Each entry records the filters so the registry can be updated
# on SUBACK/UNSUBACK.
var _pending_ops := {}
# Pending QoS>=1 PUBLISH / PUBREC waiting for PUBACK/PUBCOMP, keyed by id.
var packet_ack_queue := {}
# Incoming QoS 2 dedup: packet id -> { topic, payload }
var incoming_qos2_messages := {}
# Offline queue (bounded). Each entry: { topic, payload, retain, qos }
var _offline_queue := []
#endregion

func _ready() -> void:
	_user_client_id = client_id != ""
	if auto_connect:
		connect_to_broker()

#region public lifecycle
## Opens the WebSocket and starts the MQTT handshake. Safe to call only when
## idle or after a disconnect; returns ERR_ALREADY_IN_USE otherwise.
func connect_to_broker() -> Error:
	if _connection_state == State.CONNECTING or _connection_state == State.CONNECTED:
		_error("Already connecting/connected")
		return ERR_ALREADY_IN_USE

	# A fresh connect attempt clears any non-retryable suppression (e.g. the
	# user fixed bad credentials and is retrying on purpose).
	_reconnect_suppressed = false

	# Generate a fresh CSPRNG client ID per connect unless the user set one.
	if not _user_client_id or client_id == "":
		client_id = _generate_client_id()

	socket = WebSocketPeer.new()
	socket.supported_protocols = PackedStringArray(["mqtt"])
	socket.inbound_buffer_size = max(1024 * 1024, max_packet_size * 2)

	if OS.get_name() != "Web":
		socket.handshake_headers = PackedStringArray([
			"User-Agent: %s" % Utils.get_user_agent()
		])

	var err := socket.connect_to_url(broker)
	if err != OK:
		socket = null
		_error("Failed to open websocket: %s" % err)
		if _was_connected and auto_reconnect:
			_schedule_reconnect()
		else:
			connecting_failed.emit()
		return err

	_connection_state = State.CONNECTING
	last_packet_sent_time = Time.get_unix_time_from_system()
	connecting.emit()
	return OK

## Gracefully disconnects: sends a DISCONNECT packet, then initiates the
## WebSocket close handshake. The socket is kept alive (not nulled) so the
## outgoing DISCONNECT flushes and the close handshake completes; the
## transport-close transition in `_process` does the final cleanup and emits
## `disconnected`. Nulling the socket here would drop the send buffer and the
## broker would treat the disconnect as ungraceful (firing the Last Will).
func disconnect_from_broker() -> Error:
	# Mark the intent so the CLOSE transition goes through the DISCONNECTING
	# branch (no auto-reconnect, emits "client disconnect").
	_connection_state = State.DISCONNECTING
	if socket:
		if connection_established:
			_send_disconnect()
		socket.close()
		# Do NOT null the socket: _process keeps polling it until CLOSED,
		# which drives _on_socket_closed -> the DISCONNECTING branch.
	else:
		# No socket at all: nothing to flush, finalize immediately.
		_reset_session()
		_connection_state = State.IDLE
		disconnected.emit("client disconnect")
	return OK

func _process(_delta: float) -> void:
	# Handle scheduled reconnects.
	if _connection_state == State.RECONNECT_WAIT:
		if Time.get_unix_time_from_system() >= _reconnect_at:
			_do_reconnect()
		return

	if not socket:
		return

	socket.poll()
	var ready_state := socket.get_ready_state()

	# Detect transport-level open -> we send CONNECT once.
	if ready_state == WebSocketPeer.STATE_OPEN and not connection_established and not _connect_sent:
		if _connection_state == State.CONNECTING or _connection_state == State.RECONNECT_WAIT:
			_on_socket_open()

	# Detect transport close.
	if ready_state == WebSocketPeer.STATE_CLOSED:
		_on_socket_closed()
		return

	if ready_state != WebSocketPeer.STATE_OPEN:
		return

	# CONNACK timeout: the WebSocket handshake completed but the broker never
	# answered the MQTT CONNECT. The WebSocketPeer's own timeout only covers
	# the transport layer, not the MQTT layer, so without this a silent broker
	# would leave us in CONNECTING forever (keepalive doesn't run yet because
	# connection_established is false).
	if _connect_sent and not connection_established:
		if Time.get_unix_time_from_system() - _connect_sent_at > 10.0:
			_fail_connection("CONNACK timeout (no broker response)")

	# Drain the WebSocket receive buffer into our byte stream.
	while socket.get_available_packet_count():
		recv_stream.append_data(socket.get_packet())

	# Parse as many complete MQTT packets as available.
	_process_incoming()

	# Keep-alive / half-open detection.
	if connection_established:
		_handle_keepalive()
#endregion

#region public publish / subscribe
## Publishes `payload` to `topic`. `payload` may be a PackedByteArray (raw
## bytes, used as-is) or a String (converted via to_utf8_buffer()). Set
## `retain` to mark the message as retained on the broker. QoS 0 is the
## only guaranteed-supported level in this release; passing an unsupported
## QoS pushes an error and returns false rather than silently downgrading.
## Returns false when not connected (unless an offline queue is configured).
func publish(topic: String, payload, retain: bool = false, qos: int = 0) -> bool:
	var bytes: PackedByteArray
	if payload is PackedByteArray:
		bytes = payload
	elif payload is String:
		bytes = (payload as String).to_utf8_buffer()
	elif payload == null:
		bytes = PackedByteArray()
	else:
		_error("publish: payload must be PackedByteArray or String")
		return false

	if qos != 0 and qos != 1 and qos != 2:
		_error("publish: unsupported qos %d (only 0, 1, 2 allowed)" % qos)
		return false

	if not _is_connected():
		if offline_queue_size > 0:
			_enqueue_offline(topic, bytes, retain, qos)
			return true
		_error("publish: not connected")
		return false

	return _send_publish(topic, bytes, retain, qos)

## Subscribes to `topic_filter` at the given QoS. The filter is remembered
## and re-subscribed automatically after every reconnect.
func subscribe(topic: String, qos: int = 0) -> Error:
	subscriptions[topic] = qos
	if not _is_connected():
		return OK # will be sent after connect
	return _send_subscribe([topic])

## Unsubscribes from `topic_filter` and removes it from the registry so it
## is not re-subscribed on reconnect.
func unsubscribe(topic: String) -> Error:
	subscriptions.erase(topic)
	if not _is_connected():
		return OK
	return _send_unsubscribe([topic])

## Static MQTT 3.1.1 topic-filter matcher. `+` matches exactly one level,
## `#` only as the last level matches the remainder (including zero levels).
## Filters beginning with a wildcard do not match topics beginning with `$`.
static func topic_matches(filter: String, topic: String) -> bool:
	if filter.is_empty():
		return false

	# `$` topics are not matched by wildcard filters.
	if (filter[0] == '+' or filter[0] == '#') and not topic.is_empty() and topic[0] == '$':
		return false

	# Keep empty levels: in MQTT each level (including an empty one) is a
	# distinct, valid level. split("/", false) would collapse them, making
	# "a//b" indistinguishable from "a/b" and breaking `+` on empty levels.
	var f := filter.split("/", true)
	var t := topic.split("/", true)
	var fi := 0
	var ti := 0

	while fi < f.size():
		var fl := f[fi]

		if fl == '#':
			# `#` is only valid as the last filter level; it matches the
			# rest (including zero levels).
			return fi == f.size() - 1

		if fl == '+':
			# `+` matches exactly one level; topic must have it.
			if ti >= t.size():
				return false
			fi += 1
			ti += 1
			continue

		# Literal level: byte-exact compare.
		if ti >= t.size() or t[ti] != fl:
			return false
		fi += 1
		ti += 1

	# All filter levels consumed; a match requires all topic levels consumed.
	return ti == t.size()
#endregion

#region packet building
func _send_connect() -> Error:
	# Will — read live at CONNECT-build time (callers may update will_payload
	# between reconnects). Flat properties take precedence over the legacy
	# MqttLastWill resource.
	var p_will_topic := will_topic
	var p_will_payload := will_payload
	var p_will_qos := will_qos
	var p_will_retain := will_retain
	if p_will_topic.is_empty() and last_will != null and not last_will.topic.is_empty():
		p_will_topic = last_will.topic
		p_will_qos = last_will.qos
		p_will_retain = last_will.retain
		if p_will_payload.is_empty():
			if not last_will.msg_string.is_empty():
				p_will_payload = last_will.msg_string.to_utf8_buffer()
			else:
				p_will_payload = last_will.msg_buffer

	# Keep-alive sanity.
	var ka := keep_alive
	if ka < 0 or ka > 0xFFFF:
		ka = 30
		keep_alive = 30

	var pkt := build_connect(client_id, ka, username, password, p_will_topic, p_will_payload, p_will_qos, p_will_retain)
	return _send_raw(pkt)

func _send_publish(topic: String, payload: PackedByteArray, retain: bool, qos: int) -> bool:
	var packet_id := 0
	if qos > 0:
		packet_id = _gen_packet_id()
		packet_ack_queue[packet_id] = {
			"type" = PacketType.PUBLISH,
			"qos" = qos,
			"topic" = topic,
			"payload" = payload,
			"sent_at" = Time.get_unix_time_from_system(),
		}
	var pkt := build_publish(topic, payload, retain, qos, packet_id)
	return _send_raw(pkt) == OK

func _send_subscribe(topics: Array, qos_override := -1) -> Error:
	if topics.is_empty():
		return OK
	var packet_id := _gen_packet_id()
	# Record the filters for SUBACK-driven subscribed() signals + registry.
	_pending_ops[packet_id] = {"op": "sub", "topics": topics.duplicate()}

	var stream := PacketStream.new()
	stream.put_u16(packet_id)
	for t in topics:
		var q: int = qos_override if qos_override >= 0 else subscriptions.get(t, 0)
		stream.put_prefixed_utf8_string(t)
		stream.put_u8(clamp(q, 0, 2))
	return _send_packet(PacketType.SUBSCRIBE, PacketFlag.QOS1, stream.data_array)

func _send_unsubscribe(topics: Array) -> Error:
	if topics.is_empty():
		return OK
	var packet_id := _gen_packet_id()
	_pending_ops[packet_id] = {"op": "unsub", "topics": topics.duplicate()}

	var stream := PacketStream.new()
	stream.put_u16(packet_id)
	for t in topics:
		stream.put_prefixed_utf8_string(t)
	return _send_packet(PacketType.UNSUBSCRIBE, PacketFlag.QOS1, stream.data_array)

func send_ping() -> Error:
	if not _is_connected():
		return ERR_CONNECTION_ERROR
	last_ping_time = Time.get_unix_time_from_system()
	return _send_packet(PacketType.PINGREQ, PacketFlag.NONE)

func _send_disconnect() -> Error:
	return _send_packet(PacketType.DISCONNECT, PacketFlag.NONE)

func _send_packet(control_type: int, control_flag: int, payload := PackedByteArray()) -> Error:
	if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_CONNECTION_ERROR
	var stream := PacketStream.new()
	stream.put_u8((control_type << 4) | (control_flag & 0xF))
	stream.put_dynamic_prefixed_data(payload)
	return _send_raw(stream.data_array)

## Sends an already-assembled full packet (fixed header + remaining length +
## body) over the socket and updates the keep-alive timer.
func _send_raw(data: PackedByteArray) -> Error:
	if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_CONNECTION_ERROR
	var ok := socket.send(data) == OK
	if ok:
		last_packet_sent_time = Time.get_unix_time_from_system()
	return OK if ok else FAILED

func _gen_packet_id() -> int:
	while true:
		_last_packet_id += 1
		if _last_packet_id > 65535:
			_last_packet_id = 1
		if not _last_packet_id in packet_ack_queue and not _last_packet_id in _pending_ops:
			return _last_packet_id
	return 0
#endregion

#region incoming parsing
## Parses as many complete MQTT packets as the buffered stream holds.
## Incomplete packets are left in the buffer for the next frame. Malformed
## or oversized packets drop the connection (cannot be resynchronized).
func _process_incoming() -> void:
	while true:
		var start_pos := recv_stream.get_position()
		var control_byte := recv_stream.get_u8()
		if recv_stream.get_position() == start_pos:
			# no byte available
			break

		var ptype := control_byte >> 4
		var pflags := control_byte & 0xF

		var remaining := recv_stream.get_dynamic_int()
		if remaining == PacketStream.VARINT_INCOMPLETE:
			recv_stream.seek(start_pos)
			break
		if remaining == PacketStream.VARINT_MALFORMED:
			_fail_connection("malformed Remaining Length (bad varint)")
			return
		if remaining > max_packet_size:
			_fail_connection("packet too large: %d > %d" % [remaining, max_packet_size])
			return
		if recv_stream.bytes_left < remaining:
			recv_stream.seek(start_pos)
			break

		var payload: PackedByteArray = recv_stream.get_data(remaining)[1]

		if not _validate_packet_flags(ptype, pflags):
			_fail_connection("bad packet flags: type=%d flags=%d" % [ptype, pflags])
			return

		_on_packet(ptype, pflags, payload)

		# If the handler tore down the connection (protocol error, server
		# DISCONNECT, keepalive timeout...), stop parsing: the remaining
		# buffered bytes belong to a connection that is officially dead.
		if not _pending_fail_reason.is_empty():
			return

		# Drop consumed bytes from the head of the buffer.
		recv_stream.remove_tail()

## Validates fixed-header flags for each packet type per MQTT 3.1.1 table.
func _validate_packet_flags(ptype: int, pflags: int) -> bool:
	match ptype:
		PacketType.CONNECT, PacketType.CONNACK, PacketType.PUBACK, \
		PacketType.PUBREC, PacketType.PUBCOMP, PacketType.UNSUBACK, \
		PacketType.PINGREQ, PacketType.PINGRESP, PacketType.DISCONNECT:
			return pflags == 0
		PacketType.PUBLISH:
			# QoS 3 is illegal; bits 3 (DUP) allowed.
			var qos := (pflags & 0x06) >> 1
			return qos != 3
		PacketType.PUBREL, PacketType.SUBSCRIBE, PacketType.UNSUBSCRIBE:
			return (pflags & 0x0F) == 0x02 # reserved bits must be 0010
		_:
			# Unknown types (incl. MQTT-5 AUTH) are a protocol error.
			return false

func _on_packet(ptype: int, pflags: int, payload: PackedByteArray) -> void:
	# Any received control packet proves the connection is alive.
	last_packet_received_time = Time.get_unix_time_from_system()
	match ptype:
		PacketType.CONNACK:     _on_packet_connack(payload)
		PacketType.SUBACK:      _on_packet_suback(payload)
		PacketType.UNSUBACK:    _on_packet_unsuback(payload)
		PacketType.PUBLISH:     _on_packet_publish(payload, pflags)
		PacketType.PUBACK:      _on_packet_puback(payload)
		PacketType.PUBREC:      _on_packet_pubrec(payload)
		PacketType.PUBCOMP:     _on_packet_pubcomp(payload)
		PacketType.PUBREL:      _on_packet_pubrel(payload)
		PacketType.PINGRESP:    _on_packet_pingresp(payload)
		PacketType.DISCONNECT:
			# Server-initiated disconnect: close transport, allow reconnect.
			_fail_connection("server DISCONNECT")
		_:
			_fail_connection("unhandled packet type %d" % ptype)

func _on_packet_connack(payload: PackedByteArray) -> void:
	if payload.size() < 2:
		_fail_connection("truncated CONNACK")
		return
	var return_code := payload[1]
	if return_code != 0:
		var msg := "CONNACK return code %d" % return_code
		_error(msg)
		# Non-retryable: unacceptable protocol version (1), identifier
		# rejected (2), bad credentials (4), not authorized (5). Retrying
		# with the same params will just fail the same way.
		if return_code in [1, 2, 4, 5]:
			_reconnect_suppressed = true
		_fail_connection(msg)
		return

	# Successful connect. Mark alive timers.
	connection_established = true
	_connected_at = Time.get_unix_time_from_system()
	last_packet_received_time = _connected_at
	last_packet_sent_time = _connected_at

	# Re-subscribe all registered filters BEFORE emitting connected().
	# This prevents the consumer's immediate republish from racing its own
	# subscriptions on a reconnect.
	var filters := subscriptions.keys()
	if not filters.is_empty():
		# Send a single SUBSCRIBE carrying all filters.
		_send_subscribe(filters)

	# Flush the offline queue now that we are connected.
	_flush_offline_queue()

	var is_reconnect := _was_connected
	_was_connected = true
	connected.emit(is_reconnect)

func _on_packet_suback(payload: PackedByteArray) -> void:
	if payload.size() < 2:
		_fail_connection("truncated SUBACK")
		return
	var stream := PacketStream.new(payload)
	var packet_id := stream.get_u16()
	if not packet_id in _pending_ops:
		_error("SUBACK for unknown packet id %d" % packet_id)
		return
	var op = _pending_ops[packet_id]
	_pending_ops.erase(packet_id)
	if op.get("op", "") != "sub":
		return
	var i := 0
	for topic in op["topics"]:
		var granted := stream.get_u8()
		if granted == 0x80:
			_error("subscription refused for %s" % topic)
		else:
			subscribed.emit(topic, granted)
		i += 1

func _on_packet_unsuback(payload: PackedByteArray) -> void:
	if payload.size() < 2:
		_fail_connection("truncated UNSUBACK")
		return
	var stream := PacketStream.new(payload)
	var packet_id := stream.get_u16()
	if not packet_id in _pending_ops:
		_error("UNSUBACK for unknown packet id %d" % packet_id)
		return
	var op = _pending_ops[packet_id]
	_pending_ops.erase(packet_id)
	if op.get("op", "") != "unsub":
		return
	for topic in op["topics"]:
		subscriptions.erase(topic)
		unsubscribed.emit(topic)

func _on_packet_publish(payload: PackedByteArray, pflags: int) -> void:
	var stream := PacketStream.new(payload)
	# Topic is a UTF-8 string (length-prefixed u16).
	if stream.bytes_left < 2:
		_fail_connection("truncated PUBLISH topic")
		return
	var topic := stream.get_prefixed_utf8_string()

	var qos := 0
	if pflags & PacketFlag.QOS1:
		qos = 1
	elif pflags & PacketFlag.QOS2:
		qos = 2
	var retain := (pflags & PacketFlag.RETAIN) != 0
	# dup := (pflags & PacketFlag.DUP) != 0  # not needed by consumers

	var packet_id := 0
	if qos > 0:
		if stream.bytes_left < 2:
			_fail_connection("truncated PUBLISH packet id")
			return
		packet_id = stream.get_u16()

	# The rest of the payload is the raw message bytes (may be empty).
	var msg := stream.get_rest_data()

	if qos == 0:
		message.emit(topic, msg, retain)
		return

	# QoS 1: PUBACK, then deliver.
	if qos == 1:
		var ack := PacketStream.new()
		ack.put_u16(packet_id)
		_send_packet(PacketType.PUBACK, PacketFlag.NONE, ack.data_array)
		message.emit(topic, msg, retain)
		return

	# QoS 2: PUBREC -> (wait PUBREL) -> PUBCOMP. Dedup via packet id.
	incoming_qos2_messages[packet_id] = {"topic": topic, "payload": msg, "retained": retain}
	var rec := PacketStream.new()
	rec.put_u16(packet_id)
	_send_packet(PacketType.PUBREC, PacketFlag.NONE, rec.data_array)

func _on_packet_puback(payload: PackedByteArray) -> void:
	if payload.size() < 2:
		return
	var packet_id := (payload[0] << 8) | payload[1]
	packet_ack_queue.erase(packet_id)

func _on_packet_pubrec(payload: PackedByteArray) -> void:
	if payload.size() < 2:
		return
	var packet_id := (payload[0] << 8) | payload[1]
	if not packet_id in packet_ack_queue:
		_error("PUBREC for unknown packet id %d" % packet_id)
		return
	# Reply PUBREL with the same packet id.
	_send_packet(PacketType.PUBREL, PacketFlag.QOS1, payload)

func _on_packet_pubcomp(payload: PackedByteArray) -> void:
	if payload.size() < 2:
		return
	var packet_id := (payload[0] << 8) | payload[1]
	packet_ack_queue.erase(packet_id)

func _on_packet_pubrel(payload: PackedByteArray) -> void:
	if payload.size() < 2:
		return
	var packet_id := (payload[0] << 8) | payload[1]
	# Send PUBCOMP, then deliver the buffered QoS 2 message (once).
	_send_packet(PacketType.PUBCOMP, PacketFlag.NONE, payload)
	if packet_id in incoming_qos2_messages:
		var item = incoming_qos2_messages[packet_id]
		incoming_qos2_messages.erase(packet_id)
		message.emit(item["topic"], item["payload"], item["retained"])
	else:
		_error("PUBREL for unknown packet id %d" % packet_id)

func _on_packet_pingresp(_payload: PackedByteArray) -> void:
	current_ping = int((Time.get_unix_time_from_system() - last_ping_time) * 1000)
	ping.emit(current_ping)
#endregion

#region keepalive / half-open
func _handle_keepalive() -> void:
	if keep_alive <= 0:
		return
	var now := Time.get_unix_time_from_system()

	# Send PINGREQ when no control packet has been sent for keep_alive seconds.
	if now - last_packet_sent_time >= keep_alive:
		send_ping()

	# Half-open detection: if no packet (PINGRESP or anything else) has been
	# received within 1.5 × keep_alive, the connection is dead. We measure
	# from the last *received* packet, not from the last ping, so that an
	# alive connection with lots of outgoing traffic (which keeps pings from
	# being sent) does not false-positive, while a half-open socket that
	# stops returning PINGRESPs is still caught.
	if now - last_packet_received_time > keep_alive * 1.5:
		_fail_connection("keepalive timeout (no packet received)")
#endregion

#region reconnect / state machine
func _on_socket_open() -> void:
	# Transport is open; send the MQTT CONNECT exactly once.
	_connect_sent = true
	_connect_sent_at = Time.get_unix_time_from_system()
	_send_connect()

func _on_socket_closed() -> void:
	var was_established := connection_established
	var reason := _pending_fail_reason
	_pending_fail_reason = ""
	# Snapshot how long the session survived before _reset_session wipes it.
	# Used by _schedule_reconnect to reset the backoff attempt counter.
	if _connected_at > 0:
		_last_session_survived = Time.get_unix_time_from_system() - _connected_at
	_reset_session()
	if _connection_state == State.DISCONNECTING:
		# Intentional graceful disconnect: finalize, do not reconnect.
		_connection_state = State.IDLE
		disconnected.emit("client disconnect")
		return

	# Decide which signal to fire. A mid-session failure (protocol error,
	# keepalive timeout, server DISCONNECT) or an established transport drop
	# is a `disconnected`. A first-connect failure (transport close or bad
	# CONNACK, before the session was ever established) is a
	# `connecting_failed`. The specific reason is already on the `error`
	# channel for both paths.
	if was_established:
		disconnected.emit(reason if not reason.is_empty() else "transport closed")
	else:
		connecting_failed.emit()

	if auto_reconnect and not _reconnect_suppressed:
		_schedule_reconnect()
	else:
		_connection_state = State.IDLE

func _schedule_reconnect() -> void:
	# Reset the attempt counter only if the just-ended session survived
	# >= 30 s — a flapping broker (connects, dies within seconds) must keep
	# backing off rather than hammering at min delay forever.
	if _last_session_survived >= 30.0:
		_reconnect_attempt = 0
	_reconnect_attempt += 1
	var base := reconnect_min_delay * pow(2.0, _reconnect_attempt - 1)
	var cap := reconnect_max_delay
	var upper := min(cap, base)
	# Full jitter.
	var delay := randf_range(0.0, upper)
	_reconnect_at = Time.get_unix_time_from_system() + delay
	_connection_state = State.RECONNECT_WAIT
	reconnecting.emit(_reconnect_attempt, delay)

func _do_reconnect() -> void:
	_connection_state = State.IDLE
	connect_to_broker()

func _fail_connection(reason: String) -> void:
	if not _pending_fail_reason.is_empty():
		return # already failing; avoid re-entrancy
	_error(reason)
	if _connected_at > 0:
		_last_session_survived = Time.get_unix_time_from_system() - _connected_at
	_pending_fail_reason = reason
	# NOTE: do not clear connection_established here; _on_socket_closed needs
	# to snapshot it (was_established) to pick the right signal. _reset_session
	# (called by _on_socket_closed) clears it.
	if socket:
		socket.close()
	# Do NOT reset/emit/schedule here: the CLOSED transition in _process
	# drives _on_socket_closed, which finalizes exactly once.
#endregion

#region session reset
func _reset_session() -> void:
	socket = null
	connection_established = false
	_connect_sent = false
	_connect_sent_at = 0.0
	current_ping = -1
	recv_stream.clear()
	packet_ack_queue = {}
	_pending_ops = {}
	incoming_qos2_messages = {}
	_last_packet_id = 0
	last_ping_time = 0.0
	last_packet_sent_time = 0.0
	last_packet_received_time = 0.0
	_connected_at = 0.0
	if _connection_state != State.RECONNECT_WAIT:
		_connection_state = State.IDLE
#endregion

#region offline queue
func _enqueue_offline(topic: String, payload: PackedByteArray, retain: bool, qos: int) -> void:
	if offline_queue_size <= 0:
		return
	while _offline_queue.size() >= offline_queue_size:
		_offline_queue.pop_front()
	_offline_queue.append({"topic": topic, "payload": payload, "retain": retain, "qos": qos})

func _flush_offline_queue() -> void:
	if _offline_queue.is_empty():
		return
	var q := _offline_queue
	_offline_queue = []
	for item in q:
		_send_publish(item["topic"], item["payload"], item["retain"], item["qos"])
#endregion

#region helpers
func _is_connected() -> bool:
	return connection_established and socket != null and socket.get_ready_state() == WebSocketPeer.STATE_OPEN

func _error(text: String) -> void:
	error.emit(text)
	push_error("[mqtt-node] %s" % text)

## Generates a cryptographically random MQTT client ID of 20 chars from
## [0-9a-zA-Z], within the 1-23 char / alnum guarantee of MQTT 3.1.1.
func _generate_client_id() -> String:
	const ALPHABET := "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
	var rng := Crypto.new()
	var raw := rng.generate_random_bytes(20)
	var id := ""
	for b in raw:
		id += ALPHABET[b % ALPHABET.length()]
	return id
#endregion

#region static packet codec (pure, unit-testable)
## Encodes a MQTT variable-length integer (Remaining Length) into 1-4 bytes.
static func encode_remaining_length(value: int) -> PackedByteArray:
	var out := PackedByteArray()
	var v := value
	while true:
		var byte := v & 0x7F
		v >>= 7
		if v > 0:
			byte |= 0x80
		out.append(byte)
		if v <= 0:
			break
	return out

## Decodes a MQTT variable-length integer. Returns the value, or -1 if the
## buffer does not contain a complete varint, or -2 if malformed (>4 bytes).
static func decode_remaining_length(data: PackedByteArray) -> int:
	var value := 0
	var bit_offset := 0
	var i := 0
	while bit_offset < 7 * 4:
		if i >= data.size():
			return -1
		var byte := data[i]
		i += 1
		value |= (byte & 0x7F) << bit_offset
		bit_offset += 7
		if (byte & 0x80) == 0:
			return value
	return -2

## Builds a complete CONNECT packet (fixed header + variable header + payload)
## as raw bytes. Pure function for unit testing.
static func build_connect(p_client_id: String, p_keep_alive: int, p_username: String = "", p_password: String = "", p_will_topic: String = "", p_will_payload: PackedByteArray = PackedByteArray(), p_will_qos: int = 0, p_will_retain: bool = false) -> PackedByteArray:
	var connect_flags := 0
	connect_flags |= ConnectFlags.CLEAN_SESSION
	if not p_will_topic.is_empty():
		connect_flags |= ConnectFlags.LAST_WILL
		p_will_qos = clamp(p_will_qos, 0, 2)
		if p_will_qos == 1:
			connect_flags |= ConnectFlags.LAST_WILL_QOS_1
		elif p_will_qos == 2:
			connect_flags |= ConnectFlags.LAST_WILL_QOS_2
		if p_will_retain:
			connect_flags |= ConnectFlags.LAST_WILL_RETAIN
	if not p_username.is_empty():
		connect_flags |= ConnectFlags.USER
		if not p_password.is_empty():
			connect_flags |= ConnectFlags.PASS

	var stream := PacketStream.new()
	stream.put_prefixed_utf8_string("MQTT")
	stream.put_u8(4)
	stream.put_u8(connect_flags)
	stream.put_u16(clamp(p_keep_alive, 0, 0xFFFF))
	stream.put_prefixed_utf8_string(p_client_id)
	if not p_will_topic.is_empty():
		stream.put_prefixed_utf8_string(p_will_topic)
		stream.put_prefixed_data(p_will_payload)
	if not p_username.is_empty():
		stream.put_prefixed_utf8_string(p_username)
		if not p_password.is_empty():
			stream.put_prefixed_utf8_string(p_password)

	return _wrap_packet(PacketType.CONNECT, PacketFlag.NONE, stream.data_array)

## Builds a complete PUBLISH packet as raw bytes. Pure function for testing.
## Does not allocate a packet id (caller-supplied for QoS>0 tests).
static func build_publish(p_topic: String, p_payload: PackedByteArray, p_retain: bool, p_qos: int, p_packet_id: int = 0) -> PackedByteArray:
	var flags := 0
	if p_retain:
		flags |= PacketFlag.RETAIN
	if p_qos == 1:
		flags |= PacketFlag.QOS1
	elif p_qos == 2:
		flags |= PacketFlag.QOS2
	var stream := PacketStream.new()
	stream.put_prefixed_utf8_string(p_topic)
	if p_qos > 0:
		stream.put_u16(p_packet_id)
	stream.put_data(p_payload)
	return _wrap_packet(PacketType.PUBLISH, flags, stream.data_array)

## Wraps a variable header + payload into a full MQTT packet (fixed header
## byte + remaining length + body).
static func _wrap_packet(control_type: int, control_flag: int, payload: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.append((control_type << 4) | (control_flag & 0xF))
	out.append_array(encode_remaining_length(payload.size()))
	out.append_array(payload)
	return out

## Parses one PUBLISH packet from raw bytes (fixed header + body). Returns a
## Dictionary { topic, payload, retain, qos, packet_id } or null if the bytes
## do not form a complete/valid PUBLISH.
static func parse_publish(data: PackedByteArray) -> Variant:
	if data.is_empty():
		return null
	var ctrl := data[0]
	var ptype := ctrl >> 4
	if ptype != PacketType.PUBLISH:
		return null
	var pflags := ctrl & 0x0F
	var rl := decode_remaining_length(data.slice(1))
	if rl < 0:
		return null
	var header_len := 1 + _varint_byte_count(rl)
	if data.size() < header_len + rl:
		return null
	var body := data.slice(header_len, header_len + rl)
	var stream := PacketStream.new(body)
	if stream.bytes_left < 2:
		return null
	var topic := stream.get_prefixed_utf8_string()
	var qos := 0
	if pflags & PacketFlag.QOS1:
		qos = 1
	elif pflags & PacketFlag.QOS2:
		qos = 2
	var packet_id := 0
	if qos > 0:
		if stream.bytes_left < 2:
			return null
		packet_id = stream.get_u16()
	var payload := stream.get_rest_data()
	return {
		"topic": topic,
		"payload": payload,
		"retain": (pflags & PacketFlag.RETAIN) != 0,
		"qos": qos,
		"packet_id": packet_id,
	}

## Returns how many bytes a given remaining-length value encodes to.
static func _varint_byte_count(value: int) -> int:
	var n := 1
	var v := value
	while v > 127:
		v >>= 7
		n += 1
	return n
#endregion
