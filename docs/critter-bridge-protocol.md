# Critter bridge protocol (version 1)

The wire format between Critter (macOS) and its Android companion app. This document is the authority for the Kotlin models. Every example below is the exact output of the Swift encoder (keys sorted, no whitespace in the real frames; pretty-printed here only for the snapshot).

## Transport

- WebSocket over TLS (`wss://<host>:<port>/`). The Mac listens on the first free port in `47823...47832` (default `47823`) and advertises Bonjour service type `_critter._tcp`.
- The Mac uses a self-signed certificate. The phone does not validate a CA chain; it pins the certificate: the **TLS fingerprint is the SHA-256 of the certificate DER, as 64 lowercase hex characters**. The fingerprint comes from the pairing URI and is stored with the pairing.
- Only peers on private networks are served (10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, 127/8, ::1, fe80::/10, fc00::/7).
- Every frame is one WebSocket **text** message holding one JSON object with a `type` string. Frames larger than `1_048_576` bytes make the Mac close the connection.
- **Heartbeat = WebSocket ping/pong** (control frames). There is no application-level ping message.
- **All times are milliseconds since the Unix epoch** (`Int64`/`Long`).
- Unknown fields must be ignored. A frame the Mac cannot decode is ignored once the connection is ready.

## Connection flow

1. Phone opens the WebSocket and sends exactly one of:
   - `hello` (already paired), or
   - `pair` (first time; needs a pairing code).
2. The Mac replies:
   - to `hello`: `welcome`, then a `snapshot`; or `denied` and closes.
   - to `pair`: nothing until the user approves on the Mac, then `paired`, `welcome`, `snapshot`; or `denied` (`badCode`, `rejected`) and closes.
3. From then on the Mac pushes a new `snapshot` whenever anything changes (`seq` increases by one per connection) and answers each phone command with a `result` (or `skin`).
4. Any first frame that is not a valid `hello`/`pair`, or a `hello` with `protocol` other than `1`, gets `denied` with reason `"protocol"` and a close.

Pairing: the Mac shows a QR code with a pairing URI. A code is 8 characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`, valid 300 000 ms, single use. The device `token` returned by `paired` is 32 random bytes, base64url without padding; store it securely, it is never sent again by the Mac. The Mac stores only its SHA-256.

### Pairing URI

```
critter-pair://<host>:<port>?fp=<64 lowercase hex>&code=<code>&name=<percent-encoded Mac name>
```

IPv6 hosts are bracketed: `critter-pair://[fe80::1]:47823?...`. Everything in the query is percent-encoded (unreserved characters are `A-Z a-z 0-9 - . _ ~`); decode `name` as UTF-8.

Example:

```
critter-pair://192.168.1.20:47823?fp=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef&code=K7M2QX9P&name=Xuan%27s%20MacBook
```

## Phone -> Mac

### hello

```json
{"app":"critter-android/1.0","deviceId":"6F1C2A4E-8B7D-4C3A-9E2F-1A5B7C9D0E11","protocol":1,"token":"dG9rZW4tZXhhbXBsZS1iYXNlNjR1cmw","type":"hello"}
```

`protocol` is the protocol version (the Swift name is `protocolVersion`, the wire key is `protocol`). `app` is free-form.

### pair

```json
{"code":"K7M2QX9P","deviceName":"Pixel 9","type":"pair"}
```

### answer

`id` is an optional client-chosen correlation id, echoed in the `result`. `payload` depends on the request's `kind` (see `pending` in the snapshot).

Permission, allow:

```json
{"id":"c1","payload":{"decision":"allow"},"requestId":"req-1","type":"answer"}
```

Permission, deny (`message` optional; the Mac substitutes a default):

```json
{"id":"c2","payload":{"decision":"deny","message":"Not now"},"requestId":"req-2","type":"answer"}
```

Question:

```json
{"id":"c3","payload":{"answers":{"Which database?":"PostgreSQL"}},"requestId":"req-3","type":"answer"}
```

Plan, approve is `{"decision":"approve"}`; revise needs a non-empty `message`:

```json
{"id":"c4","payload":{"decision":"revise","message":"Split step 2"},"requestId":"req-4","type":"answer"}
```

`payload` fields: `decision` (`allow` | `deny` for permission; `approve` | `revise` for plan), `message`, `answers`. Absent fields mean "not applicable".

### AskUserQuestion answers

`payload.answers` maps the **full question text** (the `question` field of each entry in the request's `input.questions`) to the answer string. Every key must be one of the original questions and every value must be non-empty and at most 4000 characters.

- Single-select: the value is the **option label** that was chosen.
- Free text ("Other"): the value is the **text itself**.
- Multi-select (`multiSelect: true`): the value is the chosen **option labels joined with `", "`** (comma and one space), in the options' order, e.g. `"A, B"`. Verified against a real Claude Code 2.1.302 session on 2026-10-19: Claude reported receiving exactly `A, B`. The Mac passes the string through unchanged.

### seen

Tells the Mac the user has looked at a session (clears its "done"/"error" attention state).

```json
{"id":"c5","sessionId":"s1","type":"seen"}
```

### say

Sends text into a session. Trimmed text must be non-empty and at most 4000 characters.

```json
{"id":"c6","sessionId":"s1","text":"continue","type":"say"}
```

### skin

Asks for a skin's manifest (answered with a `skin` message).

```json
{"id":"c7","name":"clawd","type":"skin"}
```

## Mac -> phone

### welcome

```json
{"macName":"Xuan's MacBook","type":"welcome","version":"1.4.0"}
```

### paired

```json
{"deviceId":"6F1C2A4E-8B7D-4C3A-9E2F-1A5B7C9D0E11","macName":"Xuan's MacBook","token":"dG9rZW4tZXhhbXBsZS1iYXNlNjR1cmw","type":"paired"}
```

### denied

```json
{"reason":"badToken","type":"denied"}
```

`reason`: `badToken` (unknown device or wrong token), `badCode` (wrong, expired or used pairing code), `rejected` (the user declined on the Mac), `protocol` (version mismatch or malformed first frame). The Mac closes the connection after `denied`.

### snapshot

The complete current state; replace everything you had.

```json
{
  "type": "snapshot",
  "seq": 7,
  "sentAt": 1760000000000,
  "sessions": [
    {
      "id": "s1",
      "name": "critter",
      "source": "terminal",
      "state": "waiting",
      "detail": "Bash: swift test",
      "activity": "bash",
      "cwd": "~/CODESPACE/clawd",
      "branch": "main",
      "model": "Opus 5.5",
      "context": { "usedPercent": 42.5, "windowSize": 1000000, "estimated": false },
      "skin": "clawd",
      "eventTime": 1760000000000,
      "startedAt": 1759990000000,
      "tracked": true
    }
  ],
  "limits": {
    "fiveHour": { "usedPercentage": 12.5, "resetsAt": 1760003600000 },
    "sevenDay": { "usedPercentage": 30, "resetsAt": 1760500000000 },
    "updatedAt": 1760000000000
  },
  "pending": [
    {
      "requestId": "r1",
      "sessionId": "s1",
      "kind": "permission",
      "toolName": "Bash",
      "summary": "swift test",
      "input": { "command": "swift test" },
      "createdAt": 1760000000000,
      "expiresAt": 1760000600000
    }
  ],
  "prefs": { "skin": "clawd", "randomSkins": false, "idleDim": 0.6, "mergeThreshold": 5, "soundTheme": "pixel" }
}
```

Enums:

- `sessions[].source`: `terminal` | `vscode` | `desktop` | `other`.
- `sessions[].state`: `idle` | `running` | `waiting` | `done` | `error`.
- `pending[].kind`: `permission` | `question` | `plan`.
- `prefs.soundTheme`: `voice` | `pixel` | `marimba` | `system`.

Field notes (optional = key omitted when absent):

- `sessions` are in a stable order (oldest first). `cwd` starts with `~` when it is under the Mac user's home directory.
- `detail` (optional): a one-line status text; absent means nothing to show. `activity` (optional): kind of work in progress (e.g. `bash`); absent means unknown / none.
- `branch` (optional): git branch of `cwd`; absent means not a git repo or unknown.
- `model` (optional): model display name; absent means unknown.
- `context` (optional): absent means unknown. `usedPercent` is 0...100. `estimated` is true when it was estimated from the transcript rather than reported by Claude Code.
- `tracked`: false means Critter has not received any event from the session yet; `state` is then `idle` and not meaningful.
- `limits` (optional): absent means no rate-limit data has been seen. Each of `fiveHour`/`sevenDay` is itself optional. `usedPercentage` is 0...100; `resetsAt` and `updatedAt` are milliseconds.
- `pending` is sorted by `createdAt`, oldest first, and only holds requests of sessions listed in `sessions`. `input` is the tool input for display (long strings truncated, with the fields `command`, `plan`, `question`, `file_path`, `notebook_path`, `url` in full). A request is gone from `pending` once it is answered or the prompt is dismissed on the Mac.
- `prefs.idleDim` is 0...1.

### skin

Reply to a phone `skin` request. `manifest` is the skin's manifest JSON object; absent means the Mac has no such skin.

```json
{"id":"c7","manifest":{"name":"clawd"},"name":"clawd","type":"skin"}
```

### result

The reply to `answer`, `seen`, `say`. `id` echoes the command's `id` (absent if it had none).

Success:

```json
{"id":"c1","ok":true,"type":"result"}
```

Failure:

```json
{"id":"c1","message":"已在电脑上处理","ok":false,"reason":"resolved","type":"result"}
```

`reason` (present when `ok` is false): `resolved` (the request is already handled / gone), `invalid` (the answer or text is not acceptable), `expired`, `unavailable` (e.g. the session cannot receive text), `failed` (the Mac could not carry it out). `message` is optional human-readable text (Chinese), safe to show.
