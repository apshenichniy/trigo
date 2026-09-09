# Retained call playback

Issue #73 supplies the reusable server and native playback services consumed by
the reader in #20. Playback needs a complete verified #17 master and does not
depend on a transcript or an ASR invocation. Final deployed integration belongs
to #24.

## Transport and authority

`POST /v1/calls/{callId}/playback` accepts `RequestPlayback` using the authenticated
owner connection. A command UUID replays the same `PlaybackGrant`; renewal uses
a new command UUID. The separate grant UUID and 90-second expiration bind the
capability to the archive, call and current owner generation. Rotation/revocation
invalidates earlier capabilities. Signatures use domain-separated HMAC-SHA256
with the private high-entropy owner verifier as key material; D1 stores only
grant identities, generation and timestamps.

`GET /v1/calls/{callId}/playback/{grantId}/segments/{index}` accepts the temporary
capability in its Authorization header. Media URLs contain only opaque
identities and a segment index. Owner credentials never enter media URLs or
media requests. Both endpoints, including authentication and schema failures,
return `Cache-Control: private, no-store` and `Vary: Authorization`. The R2 bucket
remains private. Local and cloud Workers use the same HttpApi handlers.

Each segment covers at most 480,000 frames (30 seconds) of the verified stereo
16-kHz PCM master. A WAV response contains a 44-byte header and at most 1,920,000
PCM bytes. Its microphone and application channels retain the common call
timeline and source identities. It is a derived transport rendering, never a
replacement archive master. Single HTTP byte ranges, including suffix ranges,
are bounded within that segment; invalid ranges return 416 and the segment byte
length where available.

Each media request validates the live owner generation and call deletion fence,
the exact retained manifest hash, receipt/channel agreement, and R2 object size
and checksum. A request reads at most one bounded R2 range. It hashes the response
and checks live authority/deletion again after the read before returning bytes.
Missing storage, unavailable masters, no-audio calls and deleted calls have
explicit errors.

## Native service

`CallAudioPlayer` exposes load, play, pause, seek, clear and observable playback
state. Its HTTP transport uses an ephemeral URLSession without a URL cache,
rejects redirects, enforces body bounds, and verifies the WAV structure, returned
hash and timeline headers. Access remains bound to the issuing server/archive
before and after asynchronous reads.

The AVAudioEngine adapter preserves both channels. The player schedules at most
two segments, reports position from rendered source frames, and freezes call
time while paused or waiting for a buffer. An expired capability is renewed once
for the same requested segment and frame, with matching media identity. Failed
loads preserve the selected passage for resumption. Switching or clearing calls
cancels outstanding work and discards late responses.

The owner of a deletion operation must call `clear(callID:)` to release the
managed player and buffered audio. Every subsequent server request also checks
the deletion fence. #22 owns that orchestration; #20 owns visible controls. This
service creates no permanent local media cache.

## Migration and verification

Migration `0004_playback_grants.sql` adds the grant catalog and index. It does not
rewrite calls, retained media, transcript evidence or owner credentials.

The shared structural corpus covers playback request, manifest and grant shapes,
closed fields, identities, channel structure, size bounds, expiry format and
capability grammar. The same corpus runs through Effect, emitted JSON Schema
and generated Swift documents.

Server acceptance covers real private R2 ranges across a segment boundary,
exact stereo samples, suffix and invalid ranges, duplicate commands, expiry,
forged/cross-call/rotated credentials, deletion during a read, missing storage and
no-audio calls. The provider fixture rejects any ASR invocation.

Native acceptance covers renewal at 45 seconds, pause/seek, underrun recovery,
server failure, stale call responses, cancellation, strict PCM/WAV decoding and
real AVAudioEngine offline rendering. URLSession probes cover redirects, body
bounds, credential separation and changed archive bindings.

Reader integration exposed an AVAudioPlayerNode precondition failure when pause
queried progress before the engine had rendered its first frame. The adapter now
checks that the node time has a valid sample or host time before converting it,
and accepts only a valid player sample time. An untimed node reports zero rendered
frames, preserving the player's selected start position. The focused real-engine
regression starts at 500 ms and pauses before the first offline render.

At base `d917d2583a9be111f17ad16bb3e4db4ef21fefaa`, that regression terminated with
the AVAudioPlayerNode precondition failure in 49.241 seconds (source fingerprint
`5c2326d4a297115f8f973bbe9070199b714efa8113d60e71f856482c053345f2`).
After the adapter guard, all seven `PlaybackTests` passed in 27.092 seconds,
including 0.342 seconds of test execution (source fingerprint
`b846fe3bad206902450141c1edbdeaf67ad0b2217f8c70dd3c7144187b2d16ae`).
This is a demonstrated offline-engine boundary; audible-device verification
remains part of installed acceptance.

The native/local Worker smoke creates a 31-second two-source master, loses the
first local finalization receipt commit, replays the upload, and verifies normal
local media removal. It then uses the real HTTP playback client and AVAudioEngine
to seek to 30.5 seconds and back to 0.25 seconds, checking distinct expected samples
in both channels. This proves playback after cleanup independently of ASR and
reader UI; offline rendering is controlled native output, not an audible-device
or hosted-provider claim.

Run the applicable checks with:

```sh
bun run check:server
bun run check:quick --scope native
bun run check:macos:smoke
```

The scoped PR records exact candidate identity, local outcomes/timings, review
results and the full required CI run. Hosted playback of the final integrated
build and installed reader controls remain #24 acceptance.
