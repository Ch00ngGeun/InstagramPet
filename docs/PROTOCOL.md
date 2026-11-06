# Local protocol v1

Host name: `com.instagrampet.bridge`. Chrome `runtime.connectNative` carries UTF-8 JSON prefixed with a four-byte native-endian UInt32 length. Maximum input frame 64 KiB. stdout is protocol only; stderr is diagnostic metadata only.

Requests:
- `{ "version": 1, "type": "ping" }`
- DM: `{ "version": 1, "type": "dm", "eventId": "stable-id", "sender": "alice", "displayName": "Alice", "text": "Hello", "threadUrl": "https://www.instagram.com/direct/t/123/", "observedAt": "2026-11-06T01:00:00.000Z", "kind": "thread-message" }`

`kind` is `thread-message`, `inbox-preview`, or explicitly user-triggered `test`. Sender is a normalized Instagram username (no @, lowercase; ASCII letters, digits, dots, underscores, max 30). Only HTTPS `www.instagram.com/direct/t/<alphanumeric_- ID>/` links accepted; query/fragment rejected. Text max 2,000 Unicode characters; eventId max 128 `[A-Za-z0-9._:-]` characters. ISO8601 timestamp required. `displayName` optional, max 100 characters. Empty sender/text rejected. Inbox observations are previews, never full-message delivery guarantees.

Responses:
- ping: `{ "version": 1, "type": "pong", "ok": true, "queueDepth": 0, "appInstalled": true }`
- accepted or previously accepted DM: `{ "version": 1, "type": "ack", "eventId": "stable-id", "ok": true, "queued": true }`
- rejection: `{ "version": 1, "type": "error", "ok": false, "error": "description" }`

The Swift host validates before atomically placing an event in a private (0700) local queue. The Swift UI reads and removes it. An ack means queued on this Mac, not necessarily displayed. The host may launch the locally built app using an installed config. No HTTP server, network port, cookie access, private Instagram API, or external analytics.

Shared Swift API (PetCore): `PetEvent: Codable` with all fields above; `validate() throws`; `PetPaths(root: URL? = nil)` exposes `root`, `inbox`, `receipts`, `config`; `prepare() throws`; `EventQueue(paths: PetPaths)` with `enqueue(_ event: PetEvent) throws -> Bool`, `pending() throws -> [PetEvent]`, `consume(_ event: PetEvent) throws`, `count() throws -> Int`. `pending` cleans events older than 24h. New enqueue returns true, duplicate false. The app deduplicates visible event IDs and consumes an event only when first presenting its bubble; undisplayed events remain on disk across app quits. See implementation for queue bounds.
