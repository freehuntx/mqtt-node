# Changelog

## [0.2.0] - 2026-07-06

### Added

- Binary payloads end-to-end: `publish()` accepts `PackedByteArray` (raw) or
  `String`; zero-length payloads survive both directions; payloads are never
  round-tripped through UTF-8.
- `retained` flag on the `message` signal, mirroring the RETAIN bit of the
  received PUBLISH fixed header.
- Retain + QoS on publish: `publish(topic, payload, retain=false, qos=0)`.
- Last Will & Testament with binary payload via flat `will_topic`,
  `will_payload`, `will_qos`, `will_retain` properties (read live at
  CONNECT-build time so callers can refresh between reconnects).
- Cryptographically random client IDs (`Crypto.generate_random_bytes`, 20 chars
  from `[0-9a-zA-Z]`), regenerated per connect when `client_id` is empty.
- Auto-reconnect with exponential backoff + full jitter, automatic
  re-subscription of all registered filters before emitting `connected(true)`,
  and a bounded optional offline queue (`offline_queue_size`).
- `unsubscribe()` plus a static `topic_matches()` MQTT 3.1.1 filter matcher.
- Robust packet parsing: buffers across WebSocket frames, loops over multiple
  packets per frame, rejects malformed varints and oversized packets
  (`max_packet_size`), validates fixed-header flags per type.
- Half-open detection via 1.5× keep-alive PINGRESP timeout.
- CONNACK return-code surfacing; non-retryable codes (2/4/5) disable
  auto-reconnect.
- Headless unit tests (`tests/test_mqtt.gd`) for the packet codec, matcher,
  varint edges, stream reassembly, and parser fuzzing.

### Changed

- MQTT 3.1.1 (protocol level 4, name "MQTT") — already correct, now verified.
- `message` signal emits `(topic, payload: PackedByteArray, retained: bool)`.
- `connected` signal emits `(reconnection: bool)`.
- `disconnected` signal emits `(reason: String)`.
- `publish` returns `bool` instead of `Error`.
- New signals: `reconnecting(attempt, delay)`, `subscribed(topic, qos)`,
  `unsubscribed(topic)`.
- Keep-alive handled internally in `_process`; the demo's `PingTimer` is
  removed.

### Deprecated

- `MqttLastWill` resource (`last_will` property) — still read for backwards
  compatibility, but prefer the flat `will_*` properties.

### Migration

See the "Breaking changes" section in the README.

## [0.1.1] - 2026-05-31

- Fixed missing disconnect packet on close

## [0.1.0] - 2026-01-04

- Fixed logo pixels issues
- Added demo code
- Improved user-agent string
- Fixed buffer underflows
- Implemented proper qos2 logic

[0.1.0]: https://github.com/olivierlacan/keep-a-changelog/releases/tag/v0.1.0

## [0.0.1] - 2025-05-09

- Initial release
- Added mqtt3 implementation as a usable node
- Last will can be visually configured as resource

[0.0.1]: https://github.com/olivierlacan/keep-a-changelog/releases/tag/v0.0.1
