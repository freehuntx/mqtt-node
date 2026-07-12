extends SceneTree

# Headless unit tests for the mqtt-node packet codec and topic matcher.
# Run with:  godot --headless -s tests/test_mqtt.gd
#
# Tests are pure functions over PackedByteArray; no broker is contacted.

# Preload under an alias to avoid clashing with the script's own
# `class_name MqttNode` and to not depend on the (gitignored) class cache.
const Mqtt = preload("res://addons/mqtt-node/mqtt-node.gd")
const PacketStream = preload("res://addons/mqtt-node/packet-stream.gd")

var _pass := 0
var _fail := 0
var _failed_names := []

func _assert_eq(name: String, actual, expected) -> void:
	if actual is PackedByteArray and expected is PackedByteArray:
		if actual == expected:
			_pass += 1
		else:
			_fail += 1
			_failed_names.append(name)
			print("  FAIL %s\n    actual:   %s\n    expected: %s" % [name, _hex(actual), _hex(expected)])
		return
	if actual == expected:
		_pass += 1
	else:
		_fail += 1
		_failed_names.append(name)
		print("  FAIL %s\n    actual:   %s\n    expected: %s" % [name, actual, expected])

func _assert_true(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_failed_names.append(name)
		print("  FAIL %s (expected true)" % name)

func _assert_false(name: String, cond: bool) -> void:
	if not cond:
		_pass += 1
	else:
		_fail += 1
		_failed_names.append(name)
		print("  FAIL %s (expected false)" % name)

func _hex(data: PackedByteArray) -> String:
	var s := ""
	for i in range(data.size()):
		s += "%02x" % data[i]
		if i != data.size() - 1:
			s += " "
	return "[%d] %s" % [data.size(), s]

func _bytes(values: Array) -> PackedByteArray:
	var p := PackedByteArray()
	for v in values:
		p.append(v)
	return p

# ---------------------------------------------------------------------------
# Test: CONNECT encoding (no will)
# ---------------------------------------------------------------------------
func _test_connect_no_will() -> void:
	print("== CONNECT (no will) ==")
	var pkt := Mqtt.build_connect("abc", 30, "", "", "", PackedByteArray(), 0, false)
	# Expected (hand-computed): body = 15 bytes (RL=0x0F)
	# 10 0F 00 04 4D 51 54 54 04 02 00 1E 00 03 61 62 63
	var expected := _bytes([0x10,0x0F,0x00,0x04,0x4D,0x51,0x54,0x54,0x04,0x02,0x00,0x1E,0x00,0x03,0x61,0x62,0x63])
	_assert_eq("connect_no_will_bytes", pkt, expected)

	# Verify protocol name is "MQTT" and level 4 (3.1.1, not 3.1 "MQIsdp"/3).
	_assert_eq("connect_protocol_level", pkt[8], 4)
	_assert_eq("connect_clean_session_flag", pkt[9] & 0x02, 2)

# ---------------------------------------------------------------------------
# Test: CONNECT encoding with a binary retained will
# ---------------------------------------------------------------------------
func _test_connect_with_will() -> void:
	print("== CONNECT (binary retained will, qos 1) ==")
	var will := _bytes([0xDE, 0xAD])
	var pkt := Mqtt.build_connect("abc", 30, "", "", "w", will, 1, true)
	# Expected:
	# 10 16 00 04 4D 51 54 54 04 2E 00 1E
	# 00 03 61 62 63  00 01 77  00 02 DE AD
	var expected := _bytes([
		0x10,0x16,
		0x00,0x04,0x4D,0x51,0x54,0x54,0x04,0x2E,0x00,0x1E,
		0x00,0x03,0x61,0x62,0x63,
		0x00,0x01,0x77,
		0x00,0x02,0xDE,0xAD
	])
	_assert_eq("connect_with_will_bytes", pkt, expected)

	# Connect flags: Clean(0x02)|Will(0x04)|WillQoS1(0x08)|WillRetain(0x20)=0x2E
	_assert_eq("connect_will_flags", pkt[9], 0x2E)
	# Will message is raw bytes (binary-safe), not UTF-8-roundtripped.
	_assert_eq("connect_will_payload_present", pkt[pkt.size()-2], 0xDE)
	_assert_eq("connect_will_payload_present2", pkt[pkt.size()-1], 0xAD)

# ---------------------------------------------------------------------------
# Test: PUBLISH encode + decode round-trip (retain / qos bits)
# ---------------------------------------------------------------------------
func _test_publish() -> void:
	print("== PUBLISH encode/decode ==")
	# QoS 0, retain=0, topic="a/b", payload="hi"
	var p1 := Mqtt.build_publish("a/b", "hi".to_utf8_buffer(), false, 0, 0)
	var e1 := _bytes([0x30,0x07,0x00,0x03,0x61,0x2F,0x62,0x68,0x69])
	_assert_eq("publish_qos0_bytes", p1, e1)

	# QoS 0, retain=1, topic="t", zero-length payload (clears retained topic)
	var p2 := Mqtt.build_publish("t", PackedByteArray(), true, 0, 0)
	var e2 := _bytes([0x31,0x03,0x00,0x01,0x74])
	_assert_eq("publish_retain_empty_bytes", p2, e2)
	var d2 = Mqtt.parse_publish(p2)
	_assert_true("publish_retain_empty_retain", d2["retain"])
	_assert_eq("publish_retain_empty_payload", d2["payload"], PackedByteArray())
	_assert_eq("publish_retain_empty_qos", d2["qos"], 0)

	# QoS 1, retain=0, topic="t", payload=[0xFF], packet_id=0x1234
	var p3 := Mqtt.build_publish("t", _bytes([0xFF]), false, 1, 0x1234)
	var e3 := _bytes([0x32,0x06,0x00,0x01,0x74,0x12,0x34,0xFF])
	_assert_eq("publish_qos1_bytes", p3, e3)
	var d3 = Mqtt.parse_publish(p3)
	_assert_eq("publish_qos1_qos", d3["qos"], 1)
	_assert_eq("publish_qos1_packet_id", d3["packet_id"], 0x1234)
	_assert_eq("publish_qos1_payload", d3["payload"], _bytes([0xFF]))

	# Binary payload round-trip: 1 KiB of pseudo-random bytes must survive.
	var big := _make_random_bytes(1024)
	var p4 := Mqtt.build_publish("bin", big, true, 0, 0)
	var d4 = Mqtt.parse_publish(p4)
	_assert_eq("publish_binary_roundtrip", d4["payload"], big)
	_assert_true("publish_binary_retain", d4["retain"])
	_assert_eq("publish_binary_topic", d4["topic"], "bin")

	# DUP + QoS1 bit is decoded from the fixed header (0x3A = DUP|QOS1).
	var dup_pkt := _bytes([0x3A,0x06,0x00,0x01,0x74,0x12,0x34,0x01]) # DUP|QoS1
	var dd = Mqtt.parse_publish(dup_pkt)
	_assert_eq("publish_dup_qos", dd["qos"], 1)

func _make_random_bytes(n: int) -> PackedByteArray:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC0FFEE
	var p := PackedByteArray()
	p.resize(n)
	for i in range(n):
		p[i] = rng.randi() & 0xFF
	return p

# ---------------------------------------------------------------------------
# Test: Remaining Length varint edge values
# ---------------------------------------------------------------------------
func _test_remaining_length() -> void:
	print("== Remaining Length edges ==")
	_assert_eq("rl_127_enc", Mqtt.encode_remaining_length(127), _bytes([0x7F]))
	_assert_eq("rl_128_enc", Mqtt.encode_remaining_length(128), _bytes([0x80,0x01]))
	_assert_eq("rl_16383_enc", Mqtt.encode_remaining_length(16383), _bytes([0xFF,0x7F]))
	_assert_eq("rl_16384_enc", Mqtt.encode_remaining_length(16384), _bytes([0x80,0x80,0x01]))
	# Max MQTT varint value (2^28-1) encodes as FF FF FF 7F (4th byte is the
	# final byte, so its continuation bit is clear).
	_assert_eq("rl_268435455_enc", Mqtt.encode_remaining_length(268435455), _bytes([0xFF,0xFF,0xFF,0x7F]))

	_assert_eq("rl_127_dec", Mqtt.decode_remaining_length(_bytes([0x7F])), 127)
	_assert_eq("rl_128_dec", Mqtt.decode_remaining_length(_bytes([0x80,0x01])), 128)
	_assert_eq("rl_16383_dec", Mqtt.decode_remaining_length(_bytes([0xFF,0x7F])), 16383)
	_assert_eq("rl_16384_dec", Mqtt.decode_remaining_length(_bytes([0x80,0x80,0x01])), 16384)

	# Malformed: 5-byte varint (continuation on the 4th byte) -> -2.
	_assert_eq("rl_malformed", Mqtt.decode_remaining_length(_bytes([0x80,0x80,0x80,0x80,0x01])), -2)
	# Incomplete: trailing continuation byte with no following byte -> -1.
	_assert_eq("rl_incomplete", Mqtt.decode_remaining_length(_bytes([0x80])), -1)

# ---------------------------------------------------------------------------
# Test: topic_matches table (MQTT 3.1.1)
# ---------------------------------------------------------------------------
func _test_topic_matches() -> void:
	print("== topic_matches ==")
	_assert_true("a/# matches a", Mqtt.topic_matches("a/#", "a"))
	_assert_true("a/# matches a/b", Mqtt.topic_matches("a/#", "a/b"))
	_assert_true("a/# matches a/b/c", Mqtt.topic_matches("a/#", "a/b/c"))
	_assert_false("+/b does NOT match a/x/b", Mqtt.topic_matches("+/b", "a/x/b"))
	_assert_true("+/b matches a/b", Mqtt.topic_matches("+/b", "a/b"))
	_assert_true("# matches anything non-$", Mqtt.topic_matches("#", "a/b/c"))
	_assert_false("# does NOT match $SYS/x", Mqtt.topic_matches("#", "$SYS/x"))
	_assert_false("+ does NOT match $SYS/x", Mqtt.topic_matches("+", "$SYS/x"))
	_assert_true("+/+ matches a/b", Mqtt.topic_matches("+/+", "a/b"))
	_assert_false("+/+ does NOT match a", Mqtt.topic_matches("+/+", "a"))
	_assert_false("+/+ does NOT match a/b/c", Mqtt.topic_matches("+/+", "a/b/c"))
	# Empty levels are distinct valid levels (NOT collapsed by split).
	_assert_true("a//b matches a//b", Mqtt.topic_matches("a//b", "a//b"))
	_assert_true("a/# matches a//b", Mqtt.topic_matches("a/#", "a//b"))
	_assert_false("a/b does NOT match a//b (empty level is distinct)", Mqtt.topic_matches("a/b", "a//b"))
	_assert_false("a//b does NOT match a/b", Mqtt.topic_matches("a//b", "a/b"))
	# `+` must match an empty level.
	_assert_true("foo/+ matches foo/ (trailing empty level)", Mqtt.topic_matches("foo/+", "foo/"))
	_assert_false("a/b does NOT match a/c", Mqtt.topic_matches("a/b", "a/c"))
	_assert_false("a/b does NOT match ab", Mqtt.topic_matches("a/b", "ab"))
	_assert_true("literal matches itself", Mqtt.topic_matches("a/b/c", "a/b/c"))
	_assert_false("empty filter matches nothing", Mqtt.topic_matches("", "a"))

# ---------------------------------------------------------------------------
# Test: stream reassembly (parse a packet fed byte-by-byte)
# ---------------------------------------------------------------------------
func _test_stream_reassembly() -> void:
	print("== stream reassembly (byte-by-byte) ==")
	var pkt := Mqtt.build_publish("t", _bytes([0x01,0x02,0x03]), true, 0, 0)
	# pkt = 31 06 00 01 74 01 02 03  (8 bytes, RL=6)

	var stream := PacketStream.new()
	var completed := false
	var result: PackedByteArray

	for i in range(pkt.size()):
		stream.append_data(_bytes([pkt[i]]))
		var parsed = _try_parse_one(stream)
		if parsed != null:
			# Must only complete on the LAST byte.
			_assert_eq("reassembly_completes_on_last_byte", i, pkt.size() - 1)
			result = parsed
			completed = true
			break

	_assert_true("reassembly_completed", completed)
	# _try_parse_one returns the full packet body (variable header + payload):
	# topic "t" (00 01 74) + message bytes (01 02 03).
	_assert_eq("reassembly_payload", result, _bytes([0x00,0x01,0x74,0x01,0x02,0x03]))

	# Two packets concatenated in one frame: both must parse.
	var p1 := Mqtt.build_publish("a", PackedByteArray(), false, 0, 0)
	var p2 := Mqtt.build_publish("b", _bytes([0x09]), false, 0, 0)
	var both := PackedByteArray()
	both.append_array(p1)
	both.append_array(p2)

	var s2 := PacketStream.new()
	s2.append_data(both)
	var first = _try_parse_one(s2)
	_assert_true("two_packets_first", first != null)
	s2.remove_tail()
	var second = _try_parse_one(s2)
	_assert_true("two_packets_second", second != null)

	# Fuzz: random bytes must never produce an out-of-bounds crash.
	print("  fuzzing parser with 500 random byte sequences...")
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for _i in range(500):
		var n := rng.randi_range(0, 12)
		var fuzz := PackedByteArray()
		for _j in range(n):
			fuzz.append(rng.randi() & 0xFF)
		var fs := PacketStream.new()
		fs.append_data(fuzz)
		# Drain whatever parses; ignore results. Must not crash.
		while fs.bytes_left > 0:
			var r = _try_parse_one(fs)
			if r == null:
				break
			fs.remove_tail()

## Mirrors the production fixed-header parse over a PacketStream. Returns the
## packet payload (PackedByteArray) when a complete packet is available, else
## null. On malformed varint returns null (production would drop the conn).
func _try_parse_one(stream: PacketStream) -> Variant:
	if stream.bytes_left < 1:
		return null
	var start := stream.get_position()
	var ctrl := stream.get_u8()
	var remaining := stream.get_dynamic_int()
	if remaining == PacketStream.VARINT_INCOMPLETE:
		stream.seek(start)
		return null
	if remaining == PacketStream.VARINT_MALFORMED:
		return null
	if stream.bytes_left < remaining:
		stream.seek(start)
		return null
	return stream.get_data(remaining)[1]

func _init() -> void:
	print("\n========================================")
	print(" mqtt-node headless unit tests")
	print("========================================")
	_test_connect_no_will()
	_test_connect_with_will()
	_test_publish()
	_test_remaining_length()
	_test_topic_matches()
	_test_stream_reassembly()

	print("\n----------------------------------------")
	print(" PASSED: %d   FAILED: %d" % [_pass, _fail])
	if _fail > 0:
		print(" Failed tests:")
		for n in _failed_names:
			print("   - %s" % n)
	print("----------------------------------------\n")
	# Exit code: 0 on success, 1 on failure.
	quit(1 if _fail > 0 else 0)
