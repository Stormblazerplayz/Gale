# Gale file format and live sync (v1)

Every Gale app (iPad, iPhone, desktop) reads and writes the same files and speaks the same sync protocol.
The Swift reference is `Modules/GaleKit` (GaleFormat and GaleSync). The JavaScript one is `desktop/src/shared/`.
Test files that both must agree on are in `docs/fixtures/`.

## 1. Basics

- Ids are strings (Gale makes 22 lowercase letters and digits; treat any string as fine).
- Canvas pixels: (0,0) is the top left, y goes down.
- Colors are `"#RRGGBBAA"` strings (alpha last). Readers also accept `#RGB` and `#RRGGBB`.
- Dates are ISO 8601 strings. Readers also accept fractions of a second and milliseconds since 1970.
- Order: anything ordered has a `key` string. Sort by key (plain byte order), then by id. Keys come from the
  "fractional-indexing" scheme (npm `fractional-indexing`, Swift `OrderKey`): first key `"a0"`, then `"a1"`...,
  and you can always make a key between two others, so moving or inserting one thing never changes the others.
- Readers must ignore fields they don't know and fill in defaults for missing ones.

## 2. Project folder

A project is a folder `<Name>.gale/`:

```
project.json   the whole project (below)
media/         video, audio and picture files the movie uses
cover.png      small picture of the first frame (optional)
```

### project.json

```json
{
  "format": "gale/1",
  "id": "p1", "name": "Walk test",
  "created": "2026-11-15T18:00:00Z", "modified": "2026-11-15T18:05:00Z",
  "canvas": { "width": 1920, "height": 1080, "background": "#FFFFFFFF" },
  "fps": 12,
  "motionBlur": { "on": false, "amount": 0.6, "samples": 6 },
  "layers": [ { "id": "l1", "key": "a0", "name": "Layer 1", "visible": true, "locked": false, "opacity": 1 } ],
  "frames": [ { "id": "f1", "key": "a0", "hold": 1, "cels": { "l1": { "strokes": [], "fills": [] } } } ],
  "hair": [],
  "movie": { "overlay": false, "tracks": [], "clips": [] },
  "media": []
}
```

| Thing | Fields |
|---|---|
| layer | `id, key, name, visible, locked, opacity (0-1)`. Lower key = further back. |
| frame | `id, key, hold` (ticks it stays on screen, 1 = on ones), `cels` = map from layer id to cel. A missing cel is empty. |
| cel | `strokes`, `fills` (fills draw under strokes; both sorted by key). |
| stroke | `id, key, brush, pts`. |
| brush | `kind` (`pen, pencil, marker, brush, airbrush, eraser`; unknown = pen), `color`, `size` (px at full pressure), `opacity` (0-1). |
| pts | flat number list, 6 per point: `x, y, pressure (0-1), altitude (rad, pi/2 = upright), azimuth (rad), time (s since stroke start)`. Writers round x, y to 0.01 and the rest to 0.001. |
| fill | `id, key, color, path` (closed outline, flat `x, y, x, y...`). |
| hair | `id, layer, polygon` (flat x,y list), `root` (`x1,y1,x2,y2`: the attached edge), `stiffness` (0 floppy - 1 stiff), `wind` (-1..1), `gust` (0..1), `speed` (sways per second), `on`. Strokes of `layer` inside `polygon` sway (see 5). |
| motionBlur | `on, amount (0-1), samples (2-16)`. |
| media item | `id, file` (name inside `media/`), `kind` (`video, audio, image`), `name, duration` (s), `sha256` (hex of the file). |
| track | `id, key, kind` (`video, audio`), `name, muted, volume (0-2)`. |
| clip | `id, track, media` (media id, or `"animation"` for the drawing itself), `start` (s on the movie timeline), `in` (s into the source), `duration` (s of source used), `speed` (0.25-4), `volume` (0-2), `fadeIn, fadeOut` (s). Length on the timeline = duration / speed. |
| movie.overlay | true = the drawing plays on top of the video track (draw on video). |

Timing: tick = 1/fps seconds. Frame i starts at the sum of the holds before it. The animation loops when it ends.

### Pixel stories

A project with a `pixel` field is a **pixel story** (Pixel Storytime): small pixel-art scenes played one after another
with captions and speech bubbles. Apps open it in their pixel editor; `layers`/`frames` stay as they are (usually one
empty layer and frame) and `canvas` is the grid scaled up to about 1024 px with `paper` as background, for apps that only
know drawings.

```json
"pixel": {
  "width": 32, "height": 32,
  "palette": ["#00000000", "#000000FF", "#1D2B53FF"],
  "paletteName": "PICO-8",
  "paper": "#FFCCAAFF",
  "scenes": [ {
    "id": "s1", "key": "a0", "name": "Scene 1", "fps": 8, "loops": 2, "background": 0,
    "caption": "Once upon a time...", "transition": "fade",
    "bubbles": [ { "id": "b1", "text": "Hi!", "x": 0.5, "y": 0.2, "tailX": 0.45, "tailY": 0.5, "style": "speech" } ],
    "frames": [ { "id": "x1", "key": "a0", "hold": 1, "runs": [1023, 0, 1, 3] } ]
  } ]
}
```

| Thing | Fields |
|---|---|
| story | `width, height` (8-256 cells), `palette` (up to 64 `#RRGGBBAA`; index 0 is always see-through), `paletteName` (`""` once colors are edited), `paper` (color behind scenes with background 0). |
| scene | `id, key, name, fps` (1-30), `loops` (1-20, times the animation plays), `background` (palette index, 0 = paper), `caption`, `transition` (`cut, fade, wipe, iris`; unknown = cut; how the scene comes in), `bubbles`, `frames`. Sorted by key. |
| bubble | `id, text, x, y` (center, 0-1 of the art), `tailX, tailY` (where the tail points, 0-1), `style` (`speech, thought, shout, sign`; unknown = speech). |
| pixel frame | `id, key, hold` (ticks), `runs`: the cells row by row from the top left as pairs `count, palette index`. Index 0 = see-through. Missing cells are 0, extra ones dropped, indexes past the palette become 0. |

Readers fix what they can instead of failing: sizes are clamped, an empty story gets one scene, an empty scene one frame.

Playing a story: scenes play in order. A scene lasts `loops` times its animation, but at least long enough to type its
caption and bubble text at 24 letters a second (starting 0.2 s after its transition, which takes 0.5 s; `cut` takes 0)
and then 1.6 s to read; at least 0.5 s and at most 60 s. Desktop and iPad draw the same picture, byte for byte, for the
same story and time (checked by `desktop/test/fixtures/pixel-swift.json`).

## 3. Library files (not inside projects)

Stored in the app's `Library/loops/<id>.json` and `Library/stash/<id>.json`.

```json
{ "format": "gale-loop/1", "id": "w1", "name": "Bouncy walk", "kind": "walk",
  "fps": 12, "width": 1920, "height": 1080, "stride": 120,
  "frames": [ { "hold": 2, "strokes": [...], "fills": [...] } ], "created": "..." }
```
`kind`: `walk, run, idle, effect, loop`. `stride`: pixels the character moves forward per cycle (used to walk across the screen).

```json
{ "format": "gale-stash/1", "id": "s1", "name": "Tree", "auto": true, "pinned": false,
  "bounds": [x, y, w, h], "strokes": [...], "fills": [...],
  "sourceProject": "p1", "sourceFrame": "f1", "sourceLayer": "l1", "sourceStrokes": ["k1", "k2"],
  "created": "...", "updated": "..." }
```
Stash points are relative to the top left of `bounds`.

## 4. Live sync

### Objects and ops

For sync, a project is a flat set of objects. Every object has a type and fields:

| `$type` | object id | fields |
|---|---|---|
| `project` | project id | `name, width, height, background, fps, motionBlur, overlay, created`, and `pixel` for a pixel story (`{width, height, palette, paletteName, paper}`, no scenes) |
| `layer` | layer id | `key, name, visible, locked, opacity` |
| `frame` | frame id | `key, hold` |
| `stroke` | stroke id | `frame, layer, key, brush, pts` |
| `fill` | fill id | `frame, layer, key, color, path` |
| `hair` | hair id | `layer, polygon, root, stiffness, wind, gust, speed, on` |
| `track` | track id | `key, kind, name, muted, volume` |
| `clip` | clip id | `track, media, start, in, duration, speed, volume, fadeIn, fadeOut` |
| `media` | media id | `file, kind, name, duration, sha256` |
| `pxscene` | scene id | `key, name, fps, loops, background, caption, bubbles, transition` |
| `pxframe` | pixel frame id | `scene, key, hold, runs` |

Field values are the same JSON as in project.json (`brush` is the brush object, `pts` the flat list, `motionBlur` the object).
`$type` is also a field. Deleting sets the field `$del` to `true`. A stroke or fill whose frame or layer is gone (or deleted)
is ignored when building the project. So is a `pxframe` whose scene is gone, and `pxscene`/`pxframe` objects when the
project has no `pixel` field. Drawing one frame changes only that frame's `runs`.

An op changes one field of one object:

```json
{ "t": "1763229600000:00000:ipad-k3j2", "a": "ipad-k3j2", "o": "stroke-id", "k": "pts", "v": [1,2,0.5,1.571,0,0] }
```

- `t` is a hybrid logical clock: `<milliseconds, 13 digits>:<counter, 5 digits>:<actor>`. Compare as plain strings.
  On every local edit: `t = max(now, last seen ms)`; counter goes up when the ms didn't change, else resets to 0.
  When ops arrive, bump your clock past their ms/counter.
- `a` is the actor (device) id: letters, digits and `-` only.
- Merging: for each (object, field) keep the op with the biggest `t`. Order of arrival doesn't matter and
  getting an op twice doesn't matter.
- To turn a project into ops, compare the old and new flat objects and send one op per changed field
  (a new object sends all its fields including `$type`).

### Desktop hub

The desktop app is the hub. It listens on port **47820** (HTTP and WebSocket) and announces itself with Bonjour as
`_gale._tcp` (name = the computer's name). Away from home Wi-Fi it works over Tailscale (free).

Pairing (like Squall): the desktop shows a QR code with
`gale://pair?v=1&host=<ip>&port=47820&code=<6 digits>&name=<computer name>&id=<server id>`.
The code works for 2 minutes and 5 tries.

- `POST /api/v1/pair` body `{"code","deviceId","deviceName"}` → `{"token","serverId","serverName","protocolVersion":1}`
- `GET /api/v1/hello` → `{"serverId","serverName","protocolVersion":1}` (no token needed)
- Everything else needs `Authorization: Bearer <token>` (WebSocket may use `?token=` instead).
- `GET /api/v1/projects` → `[{"id","name","modified","seq"}]`
- `GET /api/v1/projects/<id>` → the project as project.json (built from the hub's objects)
- `PUT /api/v1/blobs/<sha256>` (raw bytes, the hub checks the hash), `GET` and `HEAD` the same path.

WebSocket `ws://host:47820/api/v1/sync`. Text frames, JSON, each with `"type"`:

| From | type | fields | meaning |
|---|---|---|---|
| device | `hello` | `deviceId, deviceName, since: {projectId: seq}` | start; the hub answers `welcome`, then `ops` for each project in `since` |
| hub | `welcome` | `serverId, serverName, projects: [{id,name,modified,seq}]` | |
| device | `subscribe` | `p, since` | get a project's ops from `since` (0 = everything), then live |
| device | `push` | `p, ops, ref` | local edits; the hub merges them |
| hub | `ack` | `ref, seq` | your push was saved |
| hub | `ops` | `p, ops, seq` | ops you don't have yet (only ones that won) |
| hub | `projects` | `projects` | the project list changed |
| any | `live` | `p, frame, layer, stroke, done` | a stroke while it's being drawn (not saved), ~30 per second |
| any | `presence` | `deviceId, deviceName, p, frame` | who is looking at what |
| any | `ping` / `pong` | | keep-alive every 20 s |

The hub forwards `live` and `presence` to the other devices subscribed to that project, and sends each accepted push as
`ops` to the others. `seq` counts accepted ops per project, so a device that was offline asks for `since` its last seq.
The hub keeps only the winning op per (object, field), so storage doesn't grow when things are edited many times.
