# Critter bridge protocol (version 1)

The wire format between Critter (macOS) and its Android companion app. This document is the authority for the Kotlin models. Every example below is the exact output of the Swift encoder (keys sorted, no whitespace in the real frames; pretty-printed here only for the snapshot).

## Transport

- WebSocket over TLS (`wss://<host>:<port>/`). The Mac listens on the first free port in `47823...47832` (default `47823`) and advertises Bonjour service type `_critter._tcp`.
- The Mac uses a self-signed certificate. The phone does not validate a CA chain; it pins the certificate: the **TLS fingerprint is the SHA-256 of the certificate DER, as 64 lowercase hex characters**. The fingerprint comes from the pairing URI and is stored with the pairing.
- Only peers on private networks are served (10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, 127/8, ::1, fe80::/10, fc00::/7).
- Every frame is one WebSocket **text** message holding one JSON object with a `type` string. A phone -> Mac frame larger than `1_048_576` bytes makes the Mac close the connection.
- **Mac -> phone frames are not capped.** A `snapshot` carries `command` and `plan` texts in full (see `pending`), so it can be larger than 1 MB: the phone must accept bigger frames.
- **Heartbeat = WebSocket ping/pong** (control frames). There is no application-level ping message.
- **All times are milliseconds since the Unix epoch** (`Int64`/`Long`).
- Unknown fields must be ignored. A frame the Mac cannot decode is ignored once the connection is ready.

## Connection flow

1. Phone opens the WebSocket and sends exactly one of:
   - `hello` (already paired), or
   - `pair` (first time; needs a pairing code).
2. The Mac replies:
   - to `hello`: `welcome`, then a `snapshot`; or `denied` and closes.
   - to `pair`: nothing until the user approves on the Mac, then `paired`, `welcome`, `snapshot`; or `denied` (`badCode`, `rejected`) and closes; or, if nobody answers on the Mac within 300 s, a plain close without `denied` (see *Timeouts and limits*).
3. From then on the Mac pushes a new `snapshot` whenever anything changes (`seq` increases by one per connection) and answers each phone command with a `result` (or `skin`).
4. Any first frame that is not a valid `hello`/`pair`, or a `hello` with `protocol` other than `1`, gets `denied` with reason `"protocol"` and a close.

### Timeouts and limits

All of these close the connection with a plain WebSocket close (or, before the handshake, a cancelled connection) -- **no `denied` is sent**. Values are `BridgeAdmission.standard` in the Swift code.

| What | Limit | Then |
|---|---|---|
| First frame (`hello`/`pair`) after the connection is accepted | 20 s; nothing extends it (pings don't count) | close |
| Waiting for the user to approve a `pair` on the Mac | 300 s (as long as a pairing code lives) | close, without `denied`: treat it as "not approved", the phone may try again with a new code |
| A paired (ready) connection without any frame from the phone | 600 s; **every** frame starts it over, WebSocket pings and pongs included, so the phone's heartbeat keeps it open | close |
| Connections not (yet) paired and ready -- waiting for the first frame or for approval, or closing | 8 at a time | a new connection is cancelled before the TLS/WebSocket handshake |
| Connections of any kind | 32 at a time | the same |
| Peers outside the private networks above | -- | the same |

A connection cancelled before the handshake shows up on the phone as a failed connect, not as a `denied`: back off and retry.

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

`protocol` is the protocol version (the Swift name is `protocolVersion`, the wire key is `protocol`). `app` is free-form. **All four fields are required**: a `hello` without one of them is not a valid first frame and gets `denied` `protocol`.

### pair

```json
{"code":"K7M2QX9P","deviceName":"Pixel 9","type":"pair"}
```

Both fields are required. The Mac shows and keeps `deviceName` as one line of at most 64 characters (control characters become spaces).

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

Plan, approve is `{"decision":"approve"}`; revise needs a `message` that is non-empty after trimming whitespace (Claude Code gets the trimmed text):

```json
{"id":"c4","payload":{"decision":"revise","message":"Split step 2"},"requestId":"req-4","type":"answer"}
```

`payload` fields: `decision` (`allow` | `deny` for permission; `approve` | `revise` for plan), `message`, `answers`. Absent fields mean "not applicable".

### AskUserQuestion answers

`payload.answers` maps the **full question text** (the `question` field of each entry in the request's `input.questions`) to the answer string. The keys must be exactly the request's questions -- **every question answered**, none added -- and every value must be non-empty and at most 4000 characters (after trimming whitespace). A partial answer gets `invalid`. Claude Code gets the trimmed values -- the same text that was checked.

- Single-select: the value is the **option label** that was chosen.
- Free text ("Other"): the value is the **text itself**.
- Multi-select (`multiSelect: true`): the value is the chosen **option labels joined with `", "`** (comma and one space), in the options' order, e.g. `"A, B"`. Verified against a real Claude Code 2.1.302 session on 2026-10-19: Claude reported receiving exactly `A, B`. The Mac passes the string through unchanged apart from trimming whitespace at its ends.

### seen

Tells the Mac the user has looked at a session (clears its "done"/"error" attention state).

```json
{"id":"c5","sessionId":"s1","type":"seen"}
```

### say

Sends text into a session. Trimmed text must be non-empty and at most 4000 UTF-16 code units (what Kotlin's `String.length` counts; most emoji take two), else `invalid`. The Mac sends the trimmed text.

```json
{"id":"c6","sessionId":"s1","text":"continue","type":"say"}
```

### skin

Asks for a skin's manifest (answered with a `skin` message).

```json
{"id":"c7","name":"sprig","type":"skin"}
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
      "skin": "sprig",
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
      "expiresAt": 1760000590000
    }
  ],
  "prefs": { "skin": "sprig", "randomSkins": false, "idleDim": 0.6, "mergeThreshold": 5, "soundTheme": "pixel" }
}
```

Enums:

- `sessions[].source`: `terminal` | `vscode` | `desktop` | `other` | `codex` | `codex_terminal` | `codex_vscode` | `codex_desktop`。旧客户端会把不认识的来源显示为 `other`。Codex 会话按可选 `capabilities` 开放手机操作；缺失时为只读。
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
- `pending` is sorted by `createdAt`, oldest first, and only holds requests of sessions listed in `sessions`. `expiresAt` is `createdAt + 590000` (the hook waits at most 590 s).
- `pending[].input` is the tool input for display. Every string longer than 4096 characters (Swift `Character`s, i.e. grapheme clusters) is cut to its first 4096 followed by `…` (U+2026) -- except the values of `command`, `plan`, `question`, `file_path`, `notebook_path` and `url`, which are always in full.
- A request leaves `pending` when:
  - an answer reached the hook waiting on it (the hook prints the decision and removes the request, within about 200 ms of the `result`);
  - the tool call finished: `PostToolUse`, `PostToolUseFailure` or `PermissionDenied` for that tool and input in that session. This is how an "allow" in the terminal shows -- only once the tool has finished running, so a long command's request stays listed while it runs;
  - the session moved on or ended (`UserPromptSubmit`, `Stop`, `StopFailure`, `SessionEnd`: all of that session's requests);
  - the Mac saw the session interrupted (Esc in the terminal fires no hook; Critter spots it in the transcript within a second or two) or cleaned the session up: all of its requests;
  - the hook gave up: at `expiresAt`, when the Mac app's heartbeat is more than 10 s old, or when the bridge is switched off;
  - the hook process is gone, or the request expired: the Mac sweeps those at launch and whenever it builds a snapshot.

  So a request the terminal has already settled can still be listed for a while; answering it then is harmless (see `result`).
- `prefs.idleDim` is 0...1.

### skin

Reply to a phone `skin` request. `manifest` is the skin's manifest JSON object; absent means the Mac has no such skin.

```json
{"id":"c7","manifest":{"name":"sprig"},"name":"sprig","type":"skin"}
```

### result

The reply to `answer`, `seen`, `say`. `id` echoes the command's `id` (absent if it had none).

For `answer`, **`ok: true` means "delivered to the waiting hook"** -- the answer was valid and was handed to the `critter-hook ask` waiting on that request -- **not "Claude acted on it"**. If the prompt was already settled in the terminal but the request not yet withdrawn (an "allow" while the tool is still running, or just after an Esc), the hook still takes the answer and prints it; Claude Code, having moved on, is expected to ignore it (scenario `late-answer` in `scripts/dev/e2e-phone.sh`; not yet run against a live session, spec section 13.2). Only the first answer to a request is taken; any later one gets `resolved`.

Success:

```json
{"id":"c1","ok":true,"type":"result"}
```

Failure:

```json
{"id":"c1","message":"已在电脑上处理","ok":false,"reason":"resolved","type":"result"}
```

`reason` (present when `ok` is false): `resolved` (the request is already handled / gone, or already has an answer -- only the first answer to a request is accepted, so a second phone, or a second tap, gets `resolved`), `invalid` (the answer or text is not acceptable), `expired` (an answer to a request whose `expiresAt` has come: the hook no longer waits for it, so nothing is written; message `这个请求已经过期了`), `unavailable` (e.g. the session cannot receive text), `failed` (the Mac could not carry it out). `message` is optional human-readable text (Chinese), safe to show.

## Codex control extensions (protocol 1, optional)

`sessions[].capabilities` may contain `canSay`, `canAnswer`, `canInterrupt` booleans and optional `readOnlyReason`. Older clients ignore this field; newer clients treat Codex as read-only when it is absent. `sessions[].limits` uses the existing `BridgeLimits` shape for that session’s provider; the snapshot-level `limits` remains Claude Code’s account quota.

An authenticated phone can send `{"type":"interrupt","id":"stop-1","sessionId":"codex-<uuid>"}`. It receives the normal correlated `result`; `ok:true` acknowledges the stop request, not completion of the turn. Only a currently followed owner with a known active turn ID receives the operation.

Codex messages use the existing `say` command. Current Desktop/VS Code coordination routes start or steer the existing conversation, with inherited thread settings and a fresh user message ID. No second app-server is started and no historical thread is resumed implicitly. Transport loss after writing or a timeout produces an unconfirmed-result message and is never automatically retried.

Supported native Codex pending requests become the existing permission/question cards. Question text keys map back to native question IDs. Approval input sets `acceptsDenyMessage:false`; clients hide the unsupported reason field. One-off permissions never become session-wide grants. Request IDs include canonical parameters and a fresh local generation, so cards from a previous state snapshot cannot authorize a new reused raw request ID. Unmapped/secret/verification requests stay on the computer.

Codex prompts have no synthetic phone expiry: `pending[].expiresAt` is omitted while the live owner holds the request. A maximum integer is not sent as an Android notification timeout. Owner disconnects and resolved requests withdraw the card.

## iOS push registration (protocol 1, optional)

An iPhone does not stay connected, so the Mac pushes to it through APNs. After `hello` (or `paired`) the phone tells the Mac how to reach it with a `push` frame. The protocol version stays 1: a phone that never sends it (the Android app) is unaffected, and an older Mac ignores the frame (see below).

```json
{"id":"p1","registration":{"activity":{"activityId":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","activityToken":"0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0","enabled":true,"startToken":"5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a"},"bundleId":"com.braynlabs.critter","environment":"sandbox","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","notifyDone":true,"notifyError":false,"token":"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"},"type":"push"}
```

`id` is the usual optional correlation id, echoed in the `result`. `registration`:

| Field | Type | Meaning |
|---|---|---|
| `token` | string | The APNs device token, lowercase hex. **Empty = unregister.** |
| `environment` | `"sandbox"` \| `"production"` | The APNs environment the token belongs to; the Mac sends to `api.sandbox.push.apple.com` or `api.push.apple.com` accordingly. |
| `bundleId` | string | The app's bundle id (the APNs topic). |
| `key` | string | The push key: 32 random bytes the phone makes, base64url without padding (43 characters). It seals the notification text (below). |
| `notifyDone` | bool | Push when a session is done. |
| `notifyError` | bool | Push when a session fails. |
| `activity` | object, optional | The Live Activity: `enabled` (bool), and when they exist `startToken` (the push-to-start token), `activityId` and `activityToken` (the running activity and its push token), all lowercase hex or ids. Absent = no Live Activity. |

Rules:

- **Every registration is complete and replaces the old one.** To change one thing, send everything again. An empty `token` takes the registration back: the Mac forgets everything it had for this device (the other fields are ignored).
- The Mac keeps it with the device record (`devices.json`, mode 0600). Revoking the device or resetting pairing on the Mac deletes it.
- Required: every field except `activity` and the optional parts of it. A `push` frame that is missing one cannot be decoded and is ignored, like any frame the Mac cannot decode.
- Before `hello` or `pair`, like any other frame, a `push` gets `denied` `protocol`.

The Mac answers with a `result` (`id` echoed):

- `ok: true` -- stored (or, for an empty `token`, cleared).
- `ok: false`, `reason: "invalid"`, message `推送登记无效` -- `token` is not empty but `key` is not base64url without padding of exactly 32 bytes. Nothing was stored.

**An older Mac sends no `result`.** It does not know the frame and ignores it. A phone must therefore not treat the missing reply as a lost connection (the way it would for `answer` or `say`): wait up to 10 s, then keep the connection and tell the user "这台 Mac 上的 Critter 版本太旧，收不到推送". `welcome.version` says what the Mac runs.

### Push payload

What the Mac gives APNs, and the phone and its notification service extension receive. Nothing readable is in it except `Critter` / `有会话需要你`: the notification's own title, subtitle and body are sealed in `c`.

```json push
{"aps":{"alert":{"body":"有会话需要你","title":"Critter"},"category":"permission","interruption-level":"time-sensitive","mutable-content":1,"sound":"default","thread-id":"s1"},"c":"EBESExQVFhcYGRobBtz6eS2wGInoBn90aQ1JJ7IjOiw34CTEhY2LEzIxduFyl3hAuuIrvC530RSl+396ZNhnsVSrNJPVcBrzRLdD0I0flIxrkilABPRZm/r7yt1P0ObZA+9y3ANDyKB+bEKZXno6EOA5+y9hJa13muqvV0Dj","k":"permission","r":"r1","s":"s1"}
```

| Key | Meaning |
|---|---|
| `aps.category`, `k` | What the notification is. One of `permission`, `permissionNoReason` (a permission request that cannot be denied with a reason: Codex), `question`, `plan`, `waitingElsewhere` (a session is waiting but cannot be answered on the phone: "请在电脑上处理"), `done`, `error`, `test`. These are the iOS notification category ids. |
| `aps.thread-id`, `s` | The session id. |
| `r` | The request id. Only for notifications about a request (`permission`, `permissionNoReason`, `question`, `plan`). |
| `c` | The sealed text (below). |
| `aps.mutable-content` | Always 1: the service extension opens `c`. If it cannot, the system shows the plain `Critter` / `有会话需要你`. |
| `aps.interruption-level` | `time-sensitive`, only when a session waits for the user. |

A notification's **id** is its `apns-collapse-id`: the request id for a request, otherwise `<category>:<session id>` (for example `done:s1`).

To take notifications down the Mac sends a background push naming their ids; the phone removes the delivered notifications with those ids (best effort):

```json push
{"aps":{"content-available":1},"w":["r1","done:s1"]}
```

### Sealed text

`c` is AES-256-GCM, with the push key `key` (the 32 bytes). Its value is the standard base64 (with padding) of `nonce || ciphertext || tag`: a 12-byte nonce, the ciphertext, a 16-byte tag (CryptoKit's `AES.GCM.SealedBox.combined`). The plaintext is the UTF-8 JSON `{"title":…,"subtitle":…,"body":…}`; all three are strings. The whole push JSON stays within 4096 bytes: the Mac cuts the body, then the subtitle, before sealing.

Test vector, with the `key` of the registration above (a fixed nonce, which the Mac never uses: it makes a new one each time):

```json push-text
{"body":"swift test","subtitle":"~/CODESPACE/clawd · main · 终端","title":"critter 想运行"}
```

seals to the `c` value shown in the push payload above.

### Live Activity content

The Live Activity's `ContentState`, as the Mac sends it in `content-state`. The system renders it straight from the push, so it has no text but skin and state names: nothing about a session is in it. `attributes-type` of a push-to-start is `CritterActivity`.

```json push-content
{"back":[{"skin":"mochi","state":"running"}],"counts":[{"count":2,"state":"waiting"},{"count":1,"state":"running"}],"fiveHour":12,"lead":{"skin":"sprig","state":"waiting"},"sevenDay":30,"total":3,"updatedAt":1760000000000}
```

- `counts`: how many sessions are in each state, most urgent first (`waiting`, `error`, `done`, `running`, `idle`); states with none are left out.
- `lead`: the first pet (the most urgent session); `back`: at most 2 more. Each is a `skin` name and a `state`. Absent `lead` = no sessions.
- `total`: the number of sessions. `fiveHour`, `sevenDay`: used percentage of the 5-hour and 7-day limits, 0...100; absent = unknown.
- `updatedAt`: milliseconds since the Unix epoch.
