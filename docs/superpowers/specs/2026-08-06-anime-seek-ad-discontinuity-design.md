# Anime Seek And Ad Discontinuity Design

## Background

The anime player currently renders `media_kit`'s default controls. Their seek
bar calls the native `Player.seek` API directly, bypassing
`PlaybackSessionController` and `MediaKitPlayerAdapter.seek`. The HLS gateway
therefore does not cancel stale prefetch work or record the requested target
before the backend starts seeking.

On an HLS cache miss, the gateway also downloads an entire segment into memory,
writes the complete file, and only then serves it to the player. Seeking to an
uncached point can consequently stall for a full segment download. If the stall
recovery starts before the backend reports the new position, recovery can reopen
the track at an old position or zero.

Some sources insert server-side advertisements at fixed positions. These
boundaries can change timestamps, codecs, audio configuration, encryption keys,
or `EXT-X-MAP` initialization data. The current third-party HLS model represents
only one playlist-level initialization segment, so parse-and-compose rewriting
is lossy when the source changes `EXT-X-MAP` inside the media playlist. A wrong
initialization segment or stale decoder state can produce playback errors and
loud corrupted audio after an advertisement.

## Goals

- Make every user seek pass through one application-owned playback session.
- Keep the requested seek target authoritative until the backend confirms it.
- Cancel stale HLS prefetch work and prioritize the target segment.
- Stream an uncached target segment to the player while it is being cached.
- Preserve HLS discontinuities, per-range initialization maps, keys, timestamps,
  byte ranges, media sequence information, and unknown tags during rewriting.
- Conservatively skip only explicitly marked VOD advertisement ranges.
- Reinitialize playback safely across codec, timestamp, map, or audio changes.
- Never silently recover to the beginning after a non-zero user seek.
- Support byte-range seeking for direct HTTP media when the origin supports it.

## Non-Goals

- Guessing advertisements from duration, host name, black frames, silence, or a
  bare discontinuity.
- Removing unmarked advertisements.
- Seeking arbitrary positions in a live stream without a stable seekable window.
- Circumventing authentication, payment, encryption, or DRM.
- Replacing the source API or changing anime source scripts.
- Adding thumbnail preview generation in this iteration.

## Architecture

### Application-Owned Controls

`AnimePlayerPage` will stop using the default seek bar. Its controls builder will
use the existing native video surface but provide an application-owned overlay
for play/pause, elapsed time, duration, seek bar, short seek commands,
fullscreen, and the existing episode/line/settings entry.

All seek gestures call `PlaybackSessionController.seekTo`. The controller, not
the widget or native player, owns seek state. The UI may display the dragged
target immediately without treating it as a confirmed backend position.

### Seek State

The playback session adds these concepts:

- `confirmedPosition`: the latest trustworthy backend position.
- `pendingSeekTarget`: the newest user-requested target, or null.
- `seekGeneration`: invalidates earlier rapid seek operations.
- `resumeAfterSeek`: whether playback was active before dragging.

The flow is:

1. Drag start pauses playback and cancels stall recovery.
2. Drag updates only the preview target shown by the controls.
3. Drag end records `pendingSeekTarget`, increments the seek generation, tells
   the adapter and HLS session to invalidate stale work, and calls native seek.
4. Backend positions near the target confirm the seek. Positions near zero or
   large backward jumps are ignored while confirmation is pending.
5. Playback resumes only if it was active before the gesture.
6. A timeout or backend error reopens the selected track at
   `pendingSeekTarget ?? confirmedPosition`, never at an unconfirmed zero.
7. A newer seek supersedes every callback from an older seek generation.

Near-end resume behavior remains unchanged for ordinary episode startup. It
must not convert an explicit in-session seek target to zero.

### HLS Session Priority

`HlsSession.notifySeek` will increment a generation, cancel queued forward
prefetch, and mark the next player-requested media resource as high priority.
Prefetch uses a lower-priority queue and cannot occupy the target request slot.
Repeated seeks retain only the newest generation.

### Stream-Through Cache

The upstream client gains a streaming response API instead of returning every
segment as a complete byte list. For a cache miss, the gateway will:

1. Open a temporary cache file.
2. Forward upstream chunks to the local HTTP response with backpressure.
3. Write the same chunks to the temporary file.
4. Atomically commit cache metadata and the file only after a complete,
   successful response.
5. Delete the temporary file after cancellation, length mismatch, or error.

A completed cache hit is served directly from disk. Concurrent non-owner
requests may wait for the owner to commit; the active player request must never
wait for a full download before receiving its first bytes.

Incoming local `Range` requests are honored for completed cache files. Upstream
byte ranges are forwarded with their original `206`, `Content-Range`,
`Accept-Ranges`, and length semantics. A partial miss is not committed as a
complete cache entry.

### Lossless Media Playlist Rewriting

Master playlists can continue using structured parsing. Media playlists will be
rewritten from a token stream that preserves tag order and unknown lines. Only
URI-bearing fields are replaced:

- segment URI lines;
- `URI` attributes in `EXT-X-MAP`;
- `URI` attributes in `EXT-X-KEY`;
- other explicitly supported URI tags.

Every `EXT-X-MAP` remains at its original point in the playlist. Every
`EXT-X-DISCONTINUITY`, key transition, byte range, media sequence, program date,
date range, and vendor tag is preserved unless it belongs to an explicitly
removed advertisement range.

### Conservative Advertisement Filtering

Advertisement removal applies only to VOD playlists with explicit markers. The
recognizer accepts paired or timed markers such as:

- `EXT-X-DATERANGE` whose class or SCTE attributes identify an advertisement;
- `EXT-X-CUE-OUT` and `EXT-X-CUE-IN`;
- equivalent SCTE-35 start/end markers already present as vendor tags.

Segments inside a confirmed marker range are omitted. The rewritten playlist
inserts or retains a discontinuity between the surrounding content regions and
recomputes only duration-dependent data required for a valid VOD timeline. The
visible duration excludes removed advertisements.

A bare `EXT-X-DISCONTINUITY`, an unfamiliar `DATERANGE`, or an ambiguous vendor
tag is not treated as an advertisement. Live playlists are not filtered in this
iteration; their boundary tags are preserved.

### Decoder Boundary Recovery

When playback crosses a preserved discontinuity or the effective map/audio
configuration changes, the session must not reuse stale audio decoder state.
The adapter records boundary metadata exposed by the rewritten playlist and may
reopen the current local playlist at the confirmed post-boundary position. The
old external audio attachment and attachment timer are cleared before reopening.
Audio is attached again only after the new media duration and decoder are ready.

If a backend error occurs at a boundary, recovery first refreshes the source
URL, then reopens at `pendingSeekTarget ?? confirmedPosition`. It must not save a
transient zero position to history.

## Error Handling

- Origin does not support Range: keep sequential playback and show a bounded
  notice when a direct-media seek cannot be honored.
- Expired signed URL: refresh tracks and retry the newest target.
- Stream-through cancellation: close the client response and remove the
  incomplete cache file.
- Invalid ad marker pairing: keep all segments and log a diagnostic event.
- Unsupported or malformed map transition: fall back to direct HLS playback at
  the target rather than continuing with potentially corrupt audio.
- Repeated recovery failure: stop playback with retry and line-selection
  commands; do not automatically jump to zero.

## Testing

Unit and integration coverage will include:

- seek goes through the playback session and HLS session notification;
- pending target survives transient zero and backward position events;
- recovery reopens at the pending target;
- rapid seeks retain only the newest target;
- user pause remains paused after seek;
- seek cancels stale prefetch and prioritizes the target request;
- first segment bytes reach the player before cache commit;
- cancelled or failed streams never become cache hits;
- cached and upstream Range requests return correct `206` headers and bytes;
- multiple `EXT-X-MAP` tags remain in their original positions;
- discontinuities, byte ranges, keys, and unknown tags survive rewriting;
- explicit VOD ad markers remove only the marked segments;
- bare discontinuities and ambiguous markers do not remove content;
- decoder/audio state is reset at a marked boundary;
- history never regresses to zero during seek or boundary recovery.

Focused Flutter tests are sufficient for implementation validation. Windows and
Android package builds and real-device source verification remain separate,
because this workspace does not contain deterministic third-party ad streams.

## Delivery Boundaries

Implementation stays on `codex/unified-download-manager` in separate commits for
seek state, controls, streaming/Range support, and playlist/ad handling. It is
not pushed until the user requests publication. Existing unrelated work and
source repositories are not modified.
