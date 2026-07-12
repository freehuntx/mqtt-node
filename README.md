# mqtt-node
<p align="center">
  <img src="logo.png" alt="Logo" width="200"/>
</p>

## Overview
A robust MQTT **3.1.1** client for Godot 4, written in pure GDScript and using
**WebSocket transport only** (`ws`/`wss`). There are no plans to support raw
TCP/UDP — WebSocket keeps it web-export friendly.

The addon exposes an `MqttNode` node that is fully usable from the inspector:
exported properties for broker, credentials, keep-alive, last will, and
auto-reconnect, plus signals for every lifecycle event. Binary payloads are
supported end-to-end (no UTF-8 round-tripping), the RETAIN flag is readable on
received messages, and dropped connections recover automatically with
backoff and re-subscription.

## Installation
1. Copy `addons/mqtt-node` into your Godot project's `addons/` folder.
2. Enable the addon (or just preload the script — it has no editor plugin).
3. Add an `MqttNode` node, or instantiate it from code.

## Properties

### Connection
| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `broker` | `String` | `wss://broker.hivemq.com:8884/mqtt` | WebSocket broker URL. |
| `clean_session` | `bool` | `true` | Always true in this release (persistent sessions conflict with auto-resubscribe). |
| `keep_alive` | `int` | `30` | Seconds between PINGREQs. 0 disables. Half-open detection fires at 1.5× this. |
| `client_id` | `String` | `""` | Leave empty to auto-generate a CSPRNG ID (20 chars `[0-9a-zA-Z]`) per connect. If set, reused across reconnects. |
| `username` | `String` | `""` | MQTT username (optional). |
| `password` | `String` | `""` | MQTT password (optional). |
| `auto_connect` | `bool` | `true` | Connect on `_ready`. |

### Last Will & Testament
Applied at CONNECT time only; changing them while connected has no effect
until the next (re)connect. `will_payload` is read live when the CONNECT
packet is built, so you can pre-sign a fresh will between reconnects.

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `will_topic` | `String` | `""` | Empty = no will. |
| `will_retain` | `bool` | `false` | RETAIN flag for the will message. |
| `will_qos` | `int` | `0` | Will QoS (0–2). |
| `will_payload` | `PackedByteArray` | `empty` | Raw binary will message (not a String). Set from code. |
| `last_will` | `MqttLastWill` | `null` | **Deprecated** legacy resource; the flat `will_*` properties take precedence when set. |

### Auto-reconnect
| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `auto_reconnect` | `bool` | `true` | Reconnect after drops with exponential backoff + full jitter. |
| `reconnect_min_delay` | `float` | `1.0` | Base backoff. |
| `reconnect_max_delay` | `float` | `30.0` | Backoff cap. The attempt counter resets after a connection that survived ≥ 30 s. |

### Robustness / queue
| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `max_packet_size` | `int` | `262144` | Packets whose Remaining Length exceeds this are a protocol error → disconnect. |
| `offline_queue_size` | `int` | `0` | Bounded outgoing queue while disconnected. 0 = fail-fast (default). Flushes after reconnect, dropping oldest on overflow. |

## Signals
| Signal | Description |
|--------|-------------|
| `connected(reconnection: bool)` | After CONNACK + re-subscribes sent. `reconnection` is `false` on first connect, `true` on every reconnect. |
| `disconnected(reason: String)` | Transport was open but is now closed. |
| `reconnecting(attempt: int, delay: float)` | Before each reconnect attempt, after the backoff delay is scheduled. |
| `connecting()` | Socket opening for the first time. |
| `connecting_failed()` | Initial (non-reconnect) connect attempt failed. |
| `subscribed(topic: String, qos: int)` | On SUBACK, per filter. |
| `unsubscribed(topic: String)` | On UNSUBACK, per filter. |
| `message(topic: String, payload: PackedByteArray, retained: bool)` | Incoming PUBLISH. `retained` mirrors the RETAIN bit of the received packet. |
| `ping(ms: int)` | Round-trip time from PINGREQ to PINGRESP. |
| `error(message: String)` | Non-fatal and fatal errors (bad packets, CONNACK codes, publish failures). |

## Methods
```gdscript
func connect_to_broker() -> Error
func disconnect_from_broker() -> Error
func publish(topic: String, payload, retain: bool = false, qos: int = 0) -> bool
func subscribe(topic: String, qos: int = 0) -> Error
func unsubscribe(topic: String) -> Error
func send_ping() -> Error  # normally automatic via keep_alive
```
- `publish` accepts `PackedByteArray` (raw bytes) or `String` (UTF-8). Returns
  `false` when not connected unless `offline_queue_size > 0`. QoS 1/2 are
  supported on the **receive** side (PUBACK/PUBREC/PUBREL/PUBCOMP handshake
  handled); on the **send** side QoS 1 publishes are tracked for PUBACK but
  **not** retransmitted on timeout, and pending entries are cleared on
  reconnect — so send-side is "fire and track", not strict at-least-once.
  An unsupported QoS value errors loudly and returns `false`.
- `subscribe`/`unsubscribe` update a registry that is replayed after every
  reconnect, so subscriptions survive drops without user code.

### Static helpers
```gdscript
static func topic_matches(filter: String, topic: String) -> bool
```
MQTT 3.1.1 filter matching: `+` = one level, `#` = rest (last level only,
including zero levels), literal levels compare byte-exact, and wildcard
filters do not match `$`-prefixed topics.

## Example: connect with a binary retained will, subscribe, publish
```gdscript
extends Node2D

@onready var mqtt := MqttNode.new()

func _ready() -> void:
    mqtt.broker = "wss://broker.hivemq.com:8884/mqtt"
    mqtt.auto_connect = true
    mqtt.keep_alive = 30
    mqtt.auto_reconnect = true

    # Binary retained last will (opaque bytes).
    mqtt.will_topic = "presence/me"
    mqtt.will_retain = true
    mqtt.will_qos = 1
    mqtt.will_payload = PackedByteArray([0x01, 0x02, 0x03, 0x04])

    mqtt.connected.connect(_on_connected)
    mqtt.message.connect(_on_message)
    mqtt.disconnected.connect(func(r): print("disconnected: ", r))
    mqtt.reconnecting.connect(func(a, d): print("reconnect #%d in %.1fs" % [a, d]))
    add_child(mqtt)

func _on_connected(reconnection: bool) -> void:
    print("connected (reconnect=%s)" % reconnection)
    mqtt.subscribe("chat/#")
    # Publish 1 KiB of raw binary, retained.
    var bytes := PackedByteArray()
    bytes.resize(1024)
    for i in range(1024):
        bytes[i] = i & 0xFF
    mqtt.publish("chat/bin", bytes, true, 0)

func _on_message(topic: String, payload: PackedByteArray, retained: bool) -> void:
    print("recv %s (%d bytes, retained=%s)" % [topic, payload.size(), retained])
```

## Security note on client IDs
When `client_id` is left empty, the node generates a fresh 20-char ID from
`Crypto.generate_random_bytes` on **every** connect. MQTT 3.1.1 brokers
disconnect the existing session when a duplicate client ID connects, so a
predictable or reused ID is a remote-disconnect vector. Set `client_id`
explicitly only if you have a reason to, and prefer a high-entropy value.

## Headless tests
Pure packet codec and matcher tests (no broker) live in `tests/test_mqtt.gd`:
```
godot --headless -s tests/test_mqtt.gd
```
They cover CONNECT encoding (with/without will), PUBLISH encode/decode with
retain/qos bits, Remaining Length edge values (127/128/16383/16384),
`topic_matches` table, byte-by-byte stream reassembly, and parser fuzzing.

## Breaking changes from 0.1.x → 0.2.0
- **`message` signal** now emits `(topic, payload, retained)` — the previous
  `(topic, msg)` signature is gone. Update handlers to accept `retained`.
- **`connected` signal** now emits `(reconnection: bool)`.
- **`disconnected` signal** now emits `(reason: String)`.
- **`publish` signature** changed to `publish(topic, payload, retain=false, qos=0)`
  and returns `bool` instead of `Error`. `payload` accepts `String` or
  `PackedByteArray`.
- **New signals**: `reconnecting`, `subscribed`, `unsubscribed` (renamed/aligned).
- **Last will**: prefer the flat `will_topic`/`will_payload`/`will_qos`/
  `will_retain` properties over the `MqttLastWill` resource (still read for
  backwards compatibility).
- The standalone `PingTimer` from the demo scene is no longer needed —
  keep-alive is handled internally by `_process`.
