extends StreamPeerBuffer

var bytes_left: int:
	get: return get_size() - get_position()

var size: int:
	get: return get_size()

func _init(data:=PackedByteArray(), offset:=0) -> void:
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

func get_dynamic_int() -> int:
	var start_position := get_position()
	var value := 0
	var bit_offset := 0

	while bit_offset < 7*4: # At max we read 4 bytes
		var byte := get_u8()
		var has_more := (byte & 0x80) == 0x80
		value |= (byte & 0x7F) << bit_offset
		bit_offset += 7

		if not has_more:
			return value

	seek(start_position)
	return -1

func get_prefixed_int() -> int:
	var length := get_u8()
	var data: PackedByteArray = get_data(length)[1]
	var value := 0
	# Process bytes in big-endian order:
	for i in range(data.size()):
		value = (value << 8) | data[i]
	return value

func get_dynamic_prefixed_data() -> Variant:
	var data_size := get_dynamic_int()
	if data_size == -1 or bytes_left < data_size:
		return null
	return get_data(data_size)[1]

func get_prefixed_data() -> PackedByteArray:
	var length := get_u16()
	if bytes_left < length:
		push_error("PacketStream: Not enough bytes for prefixed data. Expected %d, have %d" % [length, bytes_left])
		return PackedByteArray() # Or return null and handle upstream

	var result_arr := get_data(length)
	var error_code = result_arr[0]
	var data_bytes: PackedByteArray = result_arr[1]

	if error_code != OK:
		push_error("PacketStream: Error reading prefixed data. error_code=%s" % error_code)
		return PackedByteArray() # Or return null

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
