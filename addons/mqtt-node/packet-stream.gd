extends StreamPeerBuffer

## Return codes for varint decoding.
const VARINT_INCOMPLETE := -1
const VARINT_MALFORMED := -2

var bytes_left: int:
	get: return get_size() - get_position()

var size: int:
	get: return get_size()

func _init(data := PackedByteArray(), offset := 0) -> void:
	big_endian = true
	data_array = data
	seek(offset)

func append_data(data: PackedByteArray) -> void:
	var current_pos := get_position()
	seek(get_size())
	put_data(data)
	seek(current_pos)

func remove_tail() -> void:
	data_array = data_array.slice(get_position())
	seek(0)

func get_rest_data() -> PackedByteArray:
	return get_data(bytes_left)[1]

## Decodes a MQTT variable-length integer (Remaining Length).
## Returns the value, or:
##   VARINT_INCOMPLETE (-1) if the buffer does not yet hold a full varint.
##   VARINT_MALFORMED  (-2) if the encoding is invalid (more than 4 bytes
##   or a continuation byte after the 4th). On malformed the stream position
##   is NOT rewound: the caller should treat the stream as desynced.
func get_dynamic_int() -> int:
	var start_position := get_position()
	var value := 0
	var bit_offset := 0
	var byte_count := 0

	while bit_offset < 7 * 4: # At max we read 4 bytes
		if bytes_left == 0:
			seek(start_position)
			return VARINT_INCOMPLETE

		var byte := get_u8()
		byte_count += 1
		var has_more := (byte & 0x80) == 0x80
		value |= (byte & 0x7F) << bit_offset
		bit_offset += 7

		if not has_more:
			return value

	# A 4th continuation byte would require a 5th byte, which is illegal in
	# MQTT 3.1.1 (max 4 bytes, value <= 268435455). Leave position where it
	# is so the caller knows the stream is poisoned.
	return VARINT_MALFORMED

func get_prefixed_int() -> int:
	var length := get_u8()
	var data: PackedByteArray = get_data(length)[1]
	var value := 0
	# Process bytes in big-endian order:
	for i in range(data.size()):
		value = (value << 8) | data[i]
	return value

## Reads a length-prefixed (varint) chunk of bytes.
## Returns null when incomplete (caller should wait for more data).
## Returns VARINT_MALFORMED (-2, as int) when the varint is invalid; the
## stream is left desynced and the caller must drop the connection.
## Returns a PackedByteArray (possibly empty) when complete.
func get_dynamic_prefixed_data() -> Variant:
	var data_size := get_dynamic_int()
	if data_size == VARINT_INCOMPLETE:
		return null
	if data_size == VARINT_MALFORMED:
		return VARINT_MALFORMED
	if bytes_left < data_size:
		return null
	return get_data(data_size)[1]

func get_prefixed_data() -> PackedByteArray:
	if bytes_left < 2:
		return PackedByteArray()

	var length := get_u16()
	if bytes_left < length:
		push_error("PacketStream: Not enough bytes for prefixed data. Expected %d, have %d" % [length, bytes_left])
		return PackedByteArray()

	var result_arr := get_data(length)
	var error_code = result_arr[0]
	var data_bytes: PackedByteArray = result_arr[1]

	if error_code != OK:
		push_error("PacketStream: Error reading prefixed data. error_code=%s" % error_code)
		return PackedByteArray()

	if data_bytes.size() != length:
		push_error("PacketStream: Truncated read for prefixed data. Expected %d, got %d" % [length, data_bytes.size()])

	return data_bytes

func get_prefixed_utf8_string() -> String:
	return get_prefixed_data().get_string_from_utf8()

func put_prefixed_int(number: int) -> void:
	var data := PackedByteArray()
	while number > 0:
		var byte = number & 0xFF
		number >>= 8
		data.append(byte)
	put_u8(data.size())
	put_data(data)

func put_dynamic_int(number: int) -> void:
	if number <= 0:
		put_u8(0)
		return

	var byte_pos := 0
	while true:
		if number <= 0:
			break
		if byte_pos >= 4:
			push_error("Number too big: ", number)
			break

		var byte = number & 0x7F
		number >>= 7
		if number > 0:
			byte |= 0x80
		put_u8(byte)
		byte_pos += 1

func put_prefixed_data(data: PackedByteArray) -> void:
	put_u16(data.size())
	put_data(data)

func put_dynamic_prefixed_data(data: PackedByteArray) -> void:
	put_dynamic_int(data.size())
	put_data(data)

func put_prefixed_utf8_string(string: String) -> void:
	put_prefixed_data(string.to_utf8_buffer())
