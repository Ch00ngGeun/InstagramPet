# Instagram Pet Bridge extension

Load this directory as an **unpacked** extension in Google Chrome (`chrome://extensions`, Developer mode, Load unpacked). No JavaScript build is needed. See the project README for the Swift build and Native Messaging registration.

Open the extension's settings from its toolbar icon. Add the exact allowed Instagram username. Keep a logged-in `https://www.instagram.com/direct/inbox/` or `/direct/t/THREAD_ID/` tab open. After loading/reloading the extension, reload any already-open Instagram tabs. The content script is installed on Instagram only so it can follow Instagram's single-page navigation; it does not read other websites.

Instagram does not expose a stable public web DOM contract. **The default adapter is conservative and may require calibration in your account's layout.** This source has been tested with illustrative HTML fixtures, not a logged-in live Instagram account. Do not interpret “Observing” or a successful bridge test as proof of live DM detection.

## Sender identity and direction

- An empty allowlist sends nothing. Usernames are normalized to lowercase and matched exactly, never as a substring or display name.
- Verify a one-to-one thread's actual participant profile, then bind `THREAD_ID = username` in settings. This is useful because Instagram may expose a display name without a username. Group conversations are unsupported. A wrong binding can attribute a message to the wrong person.
- In a thread, an accessible `Message from …`/`sent by …` label provides direction, not account identity. A verified binding, explicit `@username` accessible label, or profile-picture link supplies identity. Conflicting identities are rejected. A body mention alone never proves direction or identity.
- If the layout exposes none of these direction cues, configure an **incoming-only** row selector after inspecting the page. Outgoing/self labels and an optional outgoing selector take precedence. Unrecognized locale labels require calibration.
- Message text defaults to exactly one noninteractive leaf `[dir=auto]` run. Multiple ambiguous text runs are skipped; supply `messageText` after checking the real DOM. Photos, reactions, voice messages, deleted/edited messages, and group messages are not supported as complete message events.
- Inbox rows require a DM thread link, changed preview, and an explicit unread accessibility cue (English/Korean/Japanese/Chinese phrases implemented), or a calibrated unread selector. A badge count alone is insufficient. Use a thread binding if the row supplies only a display name.

## Baseline and duplicate policy

Initial content, newly discovered inbox rows, route changes, saved settings, BFCache restores, and renderer gaps longer than two minutes become a baseline. A three-second settling period extends during initial structural changes to reduce hydration replay. There is no replay of all initial unread items. Late history loading beyond that settling period can still defeat DOM heuristics.

Thread events must append after the previously known tail while the list is near its bottom. If the old tail disappears, the tracker rebaselines. New rows with a machine-readable timestamp older than two minutes or more than one minute in the future are skipped. Scrolling up/history prepending is not treated as arrival. This trades coverage for fewer false alerts.

Stable message IDs preserve distinct repeated messages. Identical repeated rows without a stable ID or timestamp are ambiguous and skipped. Fallback identities depend on the rendered window; virtualization/reloads may cause misses or duplicates. Inbox previews without a new timestamp cannot distinguish repeated identical messages. A recurring identical preview fingerprint is deduplicated for up to 24 hours; it is not a complete message stream. Multiple arrivals between renders can collapse to a single preview.

The current supported thread's sidebar preview is suppressed to avoid a delayed duplicate of its message row. If that thread's row adapter is incomplete, this may miss its preview too. Two tabs observing the same stable event ID deduplicate in the serialized worker queue. A preview observed in one tab and the complete message observed in another can still be separate events; use a single observation tab for the least ambiguity.

## Bridge, local storage, and retries

Permissions are `storage` (local settings, pending events and fingerprints), `nativeMessaging` (the Swift host), and `alarms` (retry after an MV3 worker restart). There is no `tabs`, `cookies`, `webRequest`, `scripting`, broad host permission, remote endpoint, or analytics.

The content script has a bounded 50-event in-memory outbox for a transient worker error. The worker persists an event before acknowledging the content script. Its queue holds up to 100 events, expiring retry eligibility after five minutes; an overflow drops the oldest and records metadata. When Chrome is closed, on-disk expired data remains until the next worker cleanup. Successful native acknowledgements remove plaintext from this queue; a bounded list of 500 event-ID fingerprints remains for up to 24 hours, cleaned when the worker next operates. Removing a sender or disabling observation removes its pending normal events on the next queue pass. The explicitly requested demo is independent of the allowlist.

The alarm runs once per minute. A healthy Native Messaging port may keep the service worker alive, but correctness does not depend on an immortal worker. Pending/seen state survives worker restarts. Host errors/timeouts retain pending events, and only a matching native acknowledgement clears one. An acknowledgement means the host queued the event; it does not mean the pet displayed it. The native queue has separate documented retention.

“Send test bubble” uses an explicitly marked `test` event and never claims to be an Instagram DM. Only the extension's exact options/popup URL may request a test or manage the local queue. Only an Instagram top-frame content context may submit observations; a DM path is required for message events. No external messaging or page `postMessage` bridge is exposed.

## Diagnosis and DOM drift

Open settings → Diagnostics. Each tab reports counts and a state. Entries older than two minutes are hidden from this UI. Logs contain metadata, never message body, sender names or full thread URLs.

| State/counter | Meaning / action |
| --- | --- |
| `no-allowlist` | Add exact usernames and save. |
| `open-dm-page` | Navigate that Instagram tab to Direct; an arbitrary Instagram page need not render messages. |
| `unsupported-dom` | No candidate rows recognized. Inspect the page and calibrate selectors. |
| `unknownSender` | Verify a one-to-one thread binding or inspect the actual sender profile link. |
| `ambiguousSender` | Conflicting identities; do not broaden matching blindly. |
| `ambiguousText` | Calibrate a message-body selector, excluding reactions/UI. |
| `invalid-selector` | Fix selector syntax. This scan fails closed. |
| `capped: true` | A query exceeded 500 candidates; only the last 500 were inspected. Narrow selectors. |
| `contentPending`/`sendErrors`/`dropped` | Worker communication failure or bounded-buffer expiry/overflow. Reload after updating an extension, then test a new message. |
| Bridge error / nonzero pending | Check the host install, extension ID, signed executable and absolute host path. |

When Instagram changes layout: inspect a **new incoming** row and an **outgoing** row, select the smallest stable semantic containers, update the optional selector JSON, save/rebaseline, wait at least five seconds, and send a fresh test DM from the allowed account. Test an outgoing message and a different account too. Keep private message text out of public bug reports. Add a **redacted** fixture and regression test before changing detector heuristics. Do not copy the example `.verified-*` classes into settings; they are placeholders, not Instagram classes.

## Tests

Node 20+ is only needed for tests, not for loading the extension:

```sh
npm ci --ignore-scripts
npm test
```

Fixtures in `tests/fixtures` are synthetic contract examples, **not captured or verified live Instagram DOM**. Tests cover baseline suppression, allowlists, sender ambiguity, outgoing body mentions/self labels, startup hydration, history prepending, repeated messages, SPA changes, preview suppression, unsupported selectors, queue retry/expiry/overflow, worker restart and native acknowledgements, and service-worker trust boundaries. No test logs into Instagram or sends a real message.
