# Local protocol v1

Host name: `com.instagrampet.bridge`. Chrome `runtime.connectNative` carries UTF-8 JSON prefixed with a four-byte native-endian UInt32 length. Maximum input frame 64 KiB. stdout is protocol only; stderr is diagnostic metadata only.

Requests:

- `{ "version": 1, "type": "ping" }`
- App Instagram settings: `{ "version": 1, "type": "config" }`; read-only, with no contact values in the request.
- DM: `{ "version": 1, "type": "dm", "eventId": "stable-id", "sender": "alice", "displayName": "Alice", "text": "Hello", "threadUrl": "https://www.instagram.com/direct/t/123/", "observedAt": "2026-11-06T01:00:00.000Z", "kind": "thread-message" }`
- Read: `{ "version": 1, "type": "read", "threadUrl": "https://www.instagram.com/direct/t/123/" }`; the host supplies the read timestamp.

Chrome requests may omit `source` (defaults to `instagram`) or explicitly use `"source": "instagram"`. The host rejects every other source for both DM and read requests. Only the app's local readers can enqueue KakaoTalk or Messages events.

`kind` is `thread-message`, `inbox-preview`, or explicitly user-triggered `test`. Sender is a normalized Instagram username (no @, lowercase; ASCII letters, digits, dots, underscores, max 30). Only HTTPS `www.instagram.com/direct/t/<alphanumeric_- ID>/` links accepted; query/fragment rejected. Text max 2,000 Unicode characters; eventId max 128 `[A-Za-z0-9._:-]` characters. ISO8601 timestamp required. `displayName` optional, max 100 characters. Empty sender/text rejected. Inbox observations are previews, never full-message delivery guarantees.

Responses:

- ping: `{ "version": 1, "type": "pong", "ok": true, "queueDepth": 0, "appInstalled": true }`
- app-managed Instagram: `{ "version": 1, "type": "config", "ok": true, "instagram": { "username": "fixture.one,fixture.two", "threadId": "123456789,987654321" } }`
- no app Instagram override: `{ "version": 1, "type": "config", "ok": true, "instagram": null }`
- app-managed Instagram disabled: `{ "version": 1, "type": "config", "ok": true, "instagram": { "username": "", "threadId": "" } }`
- accepted or previously accepted DM: `{ "version": 1, "type": "ack", "eventId": "stable-id", "ok": true, "queued": true }`
- rejection: `{ "version": 1, "type": "error", "ok": false, "error": "description" }`

The Swift host validates before atomically placing an event in a private (0700) local queue. The Swift UI reads and removes it. An ack means queued on this Mac, not necessarily displayed. The host may launch the locally built app using an installed config. No HTTP server, network port, cookie access, private Instagram API, or external analytics.

## App settings synchronization

`config` uses the same registered-extension origin gate as other Chrome requests. On every request the host reloads and validates the app's private `sources.json`; it does not rely on the Native Messaging port having restarted. It returns only the Instagram override, never KakaoTalk names, Messages handles, or other local settings. Malformed values produce a generic error without echoing the file or input. The request cannot write settings, enqueue a message, mark a conversation read, or grant a permission.

The existing JSON shape is retained: `username` and `threadId` are strings containing comma-separated lists, not JSON arrays. Each list accepts at most 100 items. Canonical storage removes separator whitespace and normalizes each username to lowercase without `@`; each username item must match `[a-z0-9._]{1,30}`. Each thread item must match `[0-9]{1,128}`; unlike legacy event thread URLs, app settings accept numeric thread IDs only. The two lists must have equal counts and align by position: the first username belongs to the first thread, and so on. Thread IDs must be unique; the same username may be registered for different threads, with usernames deduplicated only when constructing the effective allowlist.

Both fields must contain valid, nonempty lists, or both must be empty to disable the app-managed Instagram source. Empty interior/trailing items, mismatched list counts, duplicate threads, and any invalid item reject the entire settings update. This is a plain comma delimiter with no quoted or escaped items. A missing/null `instagram` means no app override and preserves the extension's manual configuration.

The extension requests `config` at startup, approximately every five seconds while the worker runs, through a one-minute recovery alarm, and when its options page opens. It validates the response envelope and values again before applying a managed override as the effective allowlist and thread binding. Manual settings remain editable and are stored separately while the app override takes priority; the options page displays that priority. A null config response restores the preserved manual configuration when the private file no longer has an Instagram override. Existing observation pause, selector, and debug preferences are not contact values and remain user-controlled. A rejected response leaves the previous settings intact. Contact changes establish a fresh observation baseline rather than replaying old DOM messages.

The app presents two Instagram fields without a management toggle, with a comma-separated multiple-target note and a matching-order cue. If a legacy file has no Instagram override and both fields remain untouched, saving other sources preserves that absence. The first Instagram field edit selects app-managed settings; both fields must then contain valid aligned lists, or both be empty for explicit disablement. Clearing the fields does not restore manual mode.

The app's **설정…** window validates all fields before saving `sources.json` with owner-only mode `0600`, no-follow checks, and an atomic replacement in the private app data directory. Local `messages.handle` and `kakao.name` retain their string fields and use the same plain comma-separated format, at most 100 items per list. Each Messages handle is normalized independently, each KakaoTalk name is canonicalized independently, and normalized duplicates are removed. An empty local field disables its source; invalid/empty list items reject the complete save without partially applying other source edits. The complete settings file is limited to 16 KiB. The browser transport still receives only the Instagram portion. Settings errors and diagnostics must not contain real usernames, thread IDs, contact names, phone numbers, or email addresses.

Messages/KakaoTalk source groups contain a child reader for each selected contact. Adding or removing contacts reuses unchanged children and their baseline/outbox state. Removed contacts' bubbles and pending events are cleared while still-registered contacts in the same source and other sources remain. Read marks stay isolated by conversation; a Messages bubble chooses the registered handle matching that conversation, not the first configured handle. Existing outbox bounds apply per child reader (and per KakaoTalk notification/AX path), not as one global group bound; the shared on-disk event queue remains capped at 200 events.

Shared Swift API (PetCore): `PetEvent: Codable` with all fields above; `validate() throws`; `PetPaths(root: URL? = nil)` exposes `root`, `inbox`, `receipts`, `config`; `prepare() throws`; `EventQueue(paths: PetPaths)` with `enqueue(_ event: PetEvent) throws -> Bool`, `pending() throws -> [PetEvent]`, `consume(_ event: PetEvent) throws`, `count() throws -> Int`. `pending` cleans events older than 24h. New enqueue returns true, duplicate false. The app deduplicates visible event IDs and consumes an event only when first presenting its bubble; undisplayed events remain on disk across app quits. See implementation for queue bounds.

For local events, `source` is `kakao` or `messages`, and the existing `threadUrl` field carries an opaque conversation key: `<source>:<64 lowercase SHA-256 hex characters>`. Contact names and handles stay in the private `sources.json`; these keys are identifiers, not encryption. `SourcesConfig.instagramSelections`, `messageHandles`, and `kakaoNames` expose the validated stored strings as per-target arrays. `PetEvent.identity` combines source and event ID. `ConversationKey` combines source and conversation, and `EventQueue.markRead(_:at:)` / `reads()` use it to isolate read removal. Legacy Instagram events, receipts and read marks remain valid. Local readers retry unacknowledged events until the app has accepted or intentionally discarded them; no new browser transport or daemon is added.
