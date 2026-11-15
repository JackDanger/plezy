# Music Assistant WebSocket protocol

Plezy uses Music Assistant only to play to its speakers: it hands the server
Plex stream URLs and a player id, and never browses the server's own library.

Everything here was verified directly against a live Music Assistant **2.6.3**
server (`schema_version` 26), except where it says 2.10.9. Where a number is
quoted it was measured, not assumed.

## Transport

Single WebSocket: `ws://<host>:<port>/ws` (`wss` for https). Default port 8095.

On connect the server sends an unsolicited greeting:

```json
{
  "server_id": "fe2f5b6fd78e4608bb8b075a6c269fbf",
  "server_version": "2.6.3",
  "schema_version": 26,
  "min_supported_schema_version": 24,
  "base_url": "http://10.0.2.107:8095",
  "homeassistant_addon": false,
  "onboard_done": true
}
```

### Requests

```json
{"message_id": "<unique>", "command": "<command>", "args": {…}}
```

Responses echo `message_id` and carry either `result` or an error:

```json
{"message_id": "1", "result": …, "partial": false}
{"message_id": "1", "error_code": 12, "details": "Invalid command: …"}
```

### `partial` — chunked responses

Every response carries `partial`, and it is load-bearing. Generator commands
stream their answer as several frames sharing one `message_id`:

```json
{"message_id": "1", "result": [ …500 items… ], "partial": true}
{"message_id": "1", "result": [ …500 items… ], "partial": true}
{"message_id": "1", "result": [], "partial": false}
```

The `partial: false` frame terminates the stream and normally carries an empty
list. **A client that completes on the first frame silently truncates the
answer** — a 2,000-track playlist comes back as 500 tracks with no error.
`music/playlists/playlist_tracks` is the command that does this in practice;
`library_items` returns a single frame even at `limit: 1200`.

There are two families of `error_code`: `12` for an unknown command, and `999`
for argument validation (`Value notanint of type <class 'str'> is invalid for
limit…`, and the missing-field errors from `builtin_player/update_state`).
Treat both as request failures.

Responses can arrive out of order and interleaved with events, so match on
`message_id`; never assume the next frame is your reply.

### Events

```json
{"event": "<name>", "object_id": "<id>", "data": {…}}
```

Observed: `player_added`, `player_updated`, `players_updated`, `queue_added`,
`queue_updated`, `queue_items_updated`, `media_item_added`, `builtin_player`.

### Authentication

**None on a LAN server at schema 26.** All commands below work unauthenticated.

**Required on 2.10.9 (schema 65), verified live.** The greeting is still sent to
everyone, so a socket that has not signed in looks connected while every
command is refused. Only `auth`, `auth/login`, `auth/providers` and the like
answer before signing in.

```json
{"message_id": "1", "command": "players/all"}
→ {"message_id": "1", "error_code": 20, "details": "Authentication is required."}

{"message_id": "2", "command": "auth", "args": {"token": "…"}}
→ {"message_id": "2", "result": {"authenticated": true, "user": {…}}}
```

A socket's sign-in dies with the socket, so `auth` is sent on every connect, and
before anything else: the server only pushes events to a socket once it has
signed in.

| Code | Meaning |
| --- | --- |
| `20` | Authentication required |
| `21` | Authentication failed |
| `22` | Signed in, but this user lacks the permission |
| `23` | Token invalid or expired |

Getting a token:

1. `auth/login` with `username`, `password` and `device_name`. Bad credentials
   are **not** an error frame: the reply is a `result` of
   `{"success": false, "error": "Invalid username or password"}`. Good ones give
   `{"success": true, "access_token": "…", "user": {…}}`.
2. That session token has a 30-day sliding expiry, capped at 90 days. Send it
   with `auth`, then `auth/token/create` with a `name`, whose `result` is a bare
   string: a long-lived token lasting one year. That is the one to store.

### What changed by 2.10.9

- `builtin_player/*` is gone, removed upstream in favour of Sendspin
  (`error_code` `12`). The server can no longer stream to this app as a player,
  so a Music Assistant library track cannot play on the phone. Playing to the
  server's own speakers is unaffected, including the Plex URL path.
- Players gained `playback_state`, `group_members` and `name`; `state`,
  `group_childs` and `display_name` remain as aliases.
- `group_members` on a leader lists the leader first. A follower has
  `group_members: []`, `active_group: null`, `active_source: <leader>` and only
  `synced_to: <leader>` to identify it.
- `private` marks a player belonging to one client, such as a browser tab, and
  `hide_in_ui` is the owner's choice. Neither should be offered as an output.
- Unchanged: `player_queues/play_media` takes bare URLs, a URL still comes back
  as `current_item.streamdetails.item_id`, and `queue_time_updated` still
  carries a bare number.

### Sync groups (2.10.9)

`players/create_group_player` with `provider: "sync_group"`, `name`, `members`
and `dynamic: true` makes a permanent player with its own queue, so
`player_queues/*` and `players/cmd/volume_set` work on its id unchanged. It takes
the `config.players.write` scope: a non-admin gets `error_code` `22`, but can
still play to a group that already exists. Measured with demo players:

- The reply reports `group_members: []` whatever was accepted, and members the
  server cannot sync are dropped without an error. Read the group back from
  `players/all` to see what it kept.
- `volume_level` is always null on a group. `group_volume` holds the average of
  its members, except that it reads `0` until the group first plays.
- `supported_features` omits `seek` and `next_previous`, yet `player_queues/seek`
  and `next` work.
- While playing, the leader has `active_group: <group>` and is otherwise
  indistinguishable from a free room with members of its own.
- Starting a group takes its rooms over, from a single-room queue or from another
  group, which carries on with whoever is left.
- Rooms keep `active_source: syncgroup_…` after the group stops, and after it is
  deleted.

## Players and playback

`players/all` returns every known player:

```json
{"player_id": "RINCON_74CA6074EA9A01400", "name": "Sonos",
 "provider": "sonos", "available": true, "powered": true, "state": "idle",
 "volume_level": 4, "group_childs": [], "synced_to": null,
 "active_source": "RINCON_…", "supported_features": ["enqueue","seek",…]}
```

`provider` values seen: `sonos`, `builtin_player`. There is no `sendspin`
provider on a stock server — that is a separate protocol needing its own server,
and assuming otherwise is what left the previous app unable to play anything
locally.

Player objects are much larger than the excerpt above (36 keys), including
`display_name`, `volume_muted`, `elapsed_time`, `current_media`, `device_info`
and separate `power_control` / `volume_control` / `mute_control` entries.
Note `volume_level` **can be null** — a registered but idle `builtin_player`
reports null rather than 0, so it must not be typed as a plain int. A player is only controllable
while `available` is true — a Sonos drops out whenever another source (AirPlay,
the Sonos app) takes it, reporting `available: false` with
`active_source: "airplay"`.

Playback is driven server-side through the queue, and the queue id is the
player id:

```json
{"command": "player_queues/play_media",
 "args": {"queue_id": "<player_id>", "media": ["library://track/68057"],
          "option": "replace"}}
```

Transport: `player_queues/play_pause`, `next`, `previous`, `stop`,
`seek` (`{"position": <int seconds>}`), `shuffle` (`{"shuffle_enabled": bool}`),
`repeat` (`{"repeat_mode": "off"|"all"|"one"}`) — all keyed by `queue_id`.
Volume is per player: `players/cmd/volume_set`
`{"player_id": …, "volume_level": 0-100}`.

Favourites: `music/favorites/add_item` / `remove_item` with `{"item": "<uri>"}`.

### The queue commands lie quietly — read the queue back

Four behaviours verified on 2.6.3, none of them detectable from the reply.
Together they are why a client must never treat "what I sent" as "what the
server holds":

- **`play_media` skips uris it cannot resolve and still answers
  `result: null`.** Sending `["plex://track/12345", "library://track/193073",
  "plex://track/999"]` produced a **one-item** queue and reported success. Only
  an all-unresolvable push errors (`error_code: 2`, "No playable items found").
- **`replace_next` keeps every item *before* the current one.** `[A,B,C,D]` at
  `current_index` 1 plus `replace_next [E,F]` leaves `[A,B,E,F]` — the prefix
  survives, so the resulting queue is *longer* than the list that was sent.
- **`play_index` past the end is accepted.** `play_index(7)` on a two-item
  queue returns `null`, sets `current_index: 7` and goes idle. Silence, no
  error.
- **`play_index` into a queue another controller replaced is accepted too**,
  and plays that controller's track. Only an unknown `queue_id` errors
  (`error_code: 999`), so the diverged-but-alive case is completely silent.

The reconciliation the server does offer:

```json
{"command": "player_queues/items",
 "args": {"queue_id": "<player_id>", "limit": 50, "offset": 0}}
```

Returns the real rows in order, each with `media_item.uri`. It honours `limit`
and `offset`, measured 15–22ms for 20 rows on a LAN (~2.4 KB per row), and
answers `[]` — not an error — for a queue that does not exist or an offset past
the end. `player_queues/get` gives the summary: `items` is a **count**, plus
`current_index` and `current_item`.

`queue_items_updated` is the event that says the item list changed, and it is
precise: verified to fire for a foreign `move_item` and a `play_media`, and
**not** for `next`, `play_index` or a repeat-mode change (those emit
`queue_updated` alone). That makes it usable as an exact "re-read the queue"
trigger.

One trap in `queue_updated` itself: `current_index` and `current_item` can
disagree within a single frame. Immediately after a `play_index(1)` the frame
carried `current_index: 1` with the *previous* item's uri, and only a later
read showed the pair agreeing. So the index is a hint and the uri names what is
sounding — never conclude "diverged" from the two disagreeing.

Note the Sonos topology can go stale. Reloading the provider
(`config/providers/reload` with `{"instance_id": "sonos"}`) corrected wrong
names and a phantom unavailable player.

## Discovery

The server advertises over mDNS on the LAN, so a client can auto-discover rather
than asking for a URL.

The service type is **`_mass._tcp`** — not `_music-assistant._tcp`, which is what
the app this replaces declared and is why its auto-discovery never found
anything. Verified with `dns-sd -B _mass._tcp local.`; browsing
`_music-assistant._tcp` returns nothing on a network with a live server.

The advertised instance name is the server id, matching `server_id` in the
greeting (`fe2f5b6fd78e4608bb8b075a6c269fbf` on this network), which makes it
usable for matching a discovered server against a stored connection.

On iOS the service type must also be declared in `Info.plist` under
`NSBonjourServices` or the local-network privacy rules block the browse
entirely, with no error that points at the cause.

## Base URL

The greeting carries `base_url`, but prefer the address the client actually
connected on. A server behind a container or on a multi-homed host can advertise
an address that is not reachable from the client.
