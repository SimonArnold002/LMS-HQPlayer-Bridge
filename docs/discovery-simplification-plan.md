# Discovery: find it, add it, let the link keep it

**Status: PLAN, nothing built.** Restarted from scratch 2026-09-27; the previous draft was discarded.

## 1. The requirement

Simon, 2026-09-27:

> *"It needs to find an instance of HQPlayer and add it as a player, keep it alive whilst the
> bridge is connected."*
>
> *"This whole plan and rewrite rests on it matching the experience we have today for a user, but
> making it less reliant on the two tier structure… We have been polling way too much."*
>
> *"It cannot see it as a new player as it loses all settings."*

So, three tests every change below is held to:

1. **Every user-visible timing is the same as today or better** (§5).
2. **Discovery and the control link stop needing each other's answer** (§2).
3. **No player is ever re-keyed.** A player's id is what its prefs, playlist and sync group hang off.

## 2. Today: two parts answering each other

From `Discovery.pm` and `Plugin.pm` as they stand:

| question | who answers it today | what that costs |
|---|---|---|
| how often does discovery look? | discovery **asks the link** for every known address (`_settled` → `Plugin::_linkUpFor`): 10s if any is down, 15s if all are up | discovery's pace depends on the link |
| when does a dropped link retry? | its own backoff (2s doubling to **60s**), **plus** `reconnectNow` whenever discovery hears the address that round | the link's pace depends on discovery |
| how is a known instance kept in the table? | a **unicast probe to every known address, every round**, on top of the multicast one | one extra line in HQPlayer's log per instance per round — for instances whose link is already up |
| when is a player removed? | not connected **and** not heard by discovery for 300s (`INSTANCE_TTL`) | — (see §4.4: this one stays) |

The first three are the two-tier structure. Each part is waiting on the other, and the unicast probe
exists largely to feed the first two.

## 3. What other HQPlayer clients do

Measured, and not re-derived here: Signalyst's own `hqp-control` (4.36.1 and 6.0.1, source in
`hqp-control-601-src/`) probes once on `--discover` and quits; given an address it just connects.
Roon does **no** HQPlayer discovery at all — the user types the address, and existence is the
connection. HQPlayer never announces itself on its own protocol (0 announce verbs in Embedded 6.0.0
or Desktop 5.17.2), so polling multicast is the only way a *new* instance is ever found. UPnP is not
used, by Simon's decision.

The lesson taken: **the connection is the proof of life; discovery only finds.**

## 4. The design

### 4.1 Discovery finds, and answers nothing else

- **One multicast probe a round. No unicast probes.** A known instance needs no finding.
- **Pace depends only on discovery's own state:** 2, 4, 8, 10s while nothing has been found (today's
  cold ladder, unchanged), then **15s**. It no longer asks the link anything — `_settled` and
  `_linkUpFor` go.
- **One socket for the life of the plugin**, opened at `start`, closed at `stop`. Today it is opened
  and closed every round and lives only 1.5s of each, so a late reply is thrown away and lands on a
  closed port. Every vendor client holds one socket.
- **A link going down asks for one probe now.** One-way event, not a pace: it is what keeps a DHCP
  move as fast as today (§5) without discovery polling faster while anything is down.

### 4.2 The link keeps itself alive

- **It reconnects on its own ladder, capped at 10s instead of 60s** (`BACKOFF_MAX`). That is today's
  effective return time — today it comes from discovery's 10s round poking `reconnectNow` — so the
  latency is unchanged and discovery is no longer in the loop.
- **`reconnectNow` and the call to it in `_onInstances` go.**
- Unchanged: `connected` is the *proven* link, so a player leaves Material the instant its link
  drops, exactly like a native player.

### 4.3 Identity: the name, however it arrives

The player id is `_idFor($name)` today, and the name comes from the discovery reply.
**`<GetInfo/>` over the control link returns the same name** — measured on the rig 2026-09-20 across
a rename (`HQPlayerEmbedded`, then `ManCave`), and `.248` answers `name="MacMini"` (ledger:
*GetInfo `name` is not a second key*). That entry says it is no *better* a key than discovery's; for
this plan, being the *same* key is exactly the property needed.

So an instance reached over TCP without ever answering UDP gets **the same id** it would have got
from discovery. `_idsFor`, `_liveOf`, `_isSplit`, DHCP follow and the pair re-key guard are all
untouched.

**Measured on Desktop too**, 2026-09-27, HQPlayer Desktop 6.2.3 on Simon's MacBook Pro:
the discovery reply says `name="Mac"`, and so does `<GetInfo/>`
(`engine="6.2.3" name="Mac" platform="Mac" product="Signalyst HQPlayer Desktop"`). So both
products give the same name down both paths.

### 4.4 Removal: the one place both still meet, deliberately

A player is removed when it is **not connected and not heard for 300s** — today's rule, kept.

Link-only removal was considered and rejected on today's behaviour: a daemon that answers discovery
but refuses control (an expired trial, a wedged daemon) would be forgotten at 300s and rebuilt on
the next round, every 5 minutes, for ever — and between rebuilds the Apps feed would lose its
**Restart** row, which is the one thing a user needs for a wedged daemon. Today that instance sits
quietly with its Restart row. The rule stays as it is.

This is not the two-tier problem: it is a decision taken once, at the end, and neither part waits on
the other to do its own job.

### 4.5 Configured addresses — one box

Simon: *"a box to enter and save it to our config, not multiple boxes for each player."*

- **One field**, several addresses separated by comma, space or newline, validated on save.
  A bad entry is **named** and nothing is saved, as `hqrestart.py --allow` already does. Empty means
  the feature is off.
- **Each address is connected to over TCP and asked `GetInfo`.** Its `name` enters the same table a
  discovery reply would, so it is keyed identically (§4.3). An address that is both configured and
  discovered is one row, one player — the table is keyed by address.
- **A configured address never expires.** While it is not reachable, it is tried once per round
  (15s). A dead host costs a TCP attempt, not a line in anyone's HQPlayer log.
- **Removing and re-adding.** Simon: *"devices or networks change so a user needs the ability to
  remove it and add it again."* The box is the list: delete an address and save, and its player goes
  **at once** (not at the next round), unless discovery also hears it. Add it back and save, and it
  is identified again. Because the id comes from the HQPlayer's **name**, not the address, the
  player that comes back is the **same** player with its settings, playlist and sync group — and so
  is one whose address changed: replace the old address with the new one and the player follows.
- **This brings back a settings page.** The old `Settings.pm` went in 0.2.60–0.2.76 when the live
  view replaced it. House rules: the field must be `pref_<name>` or LMS will not save it, and a
  failing handler still renders, so a validation error is reported in the page, not thrown. A bare
  checkbox is invisible in Material's settings view, so the switch below needs the house markup.

### 4.6 Automatic discovery can be switched off

Simon: *"the option to turn off auto discovery and rely purely on IP input needs to be an option."*

- **One switch on the same page, "Find HQPlayer automatically", on by default** — so an upgrade
  changes nothing for anyone who does not touch it.
- **Off means no UDP at all**: discovery is not started, no socket is opened, no probe is sent, so
  the bridge writes **nothing** to any HQPlayer's log. The link-drop `probeNow` is a no-op.
- **Players come only from the box.** On saving it off, every player whose address is not in the
  box is removed at once; its settings stay under its id, so typing its address later brings the
  same player back.
- **Removal is then the box alone.** "Not heard by discovery" cannot apply, so a configured player
  stays for as long as its address is in the box. It still leaves Material the instant its link
  drops, as every player does.
- **A DHCP move is not followed** with discovery off — there is nothing to hear the new address.
  The user updates the box (or gives HQPlayer a fixed address). Said on the settings page, next to
  the switch.
- **Off with an empty box is refused on save**, with the reason, rather than saved as a bridge that
  can never find anything — the same rule as `hqrestart.py` refusing an empty allow list.

## 5. Today vs after, scenario by scenario

| what happens | today | after | |
|---|---|---|---|
| LMS starts, HQPlayer already running | probe at start, player on the first reply | same | = |
| HQPlayer started later, nothing known | ≤10s (2/4/8/10 ladder) | same ladder | = |
| a second HQPlayer switched on, first connected | ≤15s | ≤15s | = |
| HQPlayer quits or is switched off | gone from Material instantly; forgotten after 300s | same | = |
| settings-change restart (2–6s gap) | back when the link re-proves (2s, 4s…) | same ladder | = |
| back after a long outage, player still held | ≤10s (discovery's 10s round → `reconnectNow`) | ≤10s (link's own 10s cap) | = |
| back after the player was forgotten | found by the next round | same | = |
| DHCP moves the host | link drops (watchdog, ~40s), then ≤10s to the next round | link drops, then a probe **immediately** | = or better |
| a same-named pair shrinks to one | survivor takes the plain id, guard stops a duplicate | same — code untouched | = |
| daemon answers discovery, refuses control | player invisible, Restart row stays, retried each ~10s | same, retried on the link's ≤10s ladder | = |
| multicast unreliable, instance connected | kept (unicast sustains the table; the link would anyway) | kept by its link | = |
| multicast unreliable, instance **not** connected | kept while unicast answers | removed after 300s — **type its address** | changed |
| multicast blocked entirely | never found | **type its address** | better |
| HQPlayer on two active interfaces | permanent split into two players (declined scope) | the unused address ages out after 300s and they collapse to the plain id | changed, unsupported config |

The two "changed" rows are the only departures, and both are on configurations the address box
exists for or that are already declined as scope.

New cases, which have no "today":

| what happens | after |
|---|---|
| an address is removed from the box | its player goes on save, unless discovery also hears it |
| the same address is added back | identified over TCP; the **same** player returns with its settings |
| HQPlayer's address changes, discovery **on** | followed automatically, as today |
| HQPlayer's address changes, discovery **off** | its link drops; replace the address in the box and the same player returns |
| discovery switched **off** | no UDP at all; players not in the box go on save |
| discovery **off**, box empty | refused on save, with the reason |

## 6. The polling

Lines written to **each** HQPlayer's log (hqplayerd logs every probe it receives, multicast or
unicast — the 92% complaint of 2026-09-25):

| state | 1.0.16 (flat 5s) | today | after |
|---|---|---|---|
| everything connected | ~54/min measured | 8/min (multicast + unicast every 15s) | **4/min** (multicast every 15s) |
| an instance up but refusing control | — | 12/min (both probes every 10s) | **4/min** |
| two instances, both connected | — | 8/min each | **4/min each** |

Half today's noise with no change of pace, and it no longer grows with the number of instances.
The link's own traffic (`Status` when quiet for 10s) is unchanged.

## 7. Decisions

1. **IP addresses only in the box, no hostnames** (Simon, 2026-09-27). Resolving a name is a
   blocking DNS call in LMS's event loop, and `hqrestart.py --allow` refuses host names for the same
   reason. Validation refuses a hostname and names it.
2. **`GetInfo` name = discovery name on Desktop as well as Embedded** — measured 2026-09-27, §4.3.
3. **Addresses can be removed and re-added, and automatic discovery can be switched off**
   (Simon, 2026-09-27) — §4.5 and §4.6. Discovery stays **on** by default.

Nothing is left open.

## 8. What changes in the code

**Deleted:** the unicast loop in `Discovery::_probe`; `_settled`; `COLD_PERIOD` as a link-state
pace; the per-round socket open/close; `Plugin::_linkUpFor` and its argument to `Discovery->start`;
`Control::reconnectNow` and its call in `_onInstances`.

**Changed:** `BACKOFF_MAX` 60 → 10. `Discovery` gains `probeNow`, called on a link drop (Platin
Bridge's `Discovery.pm` has one, so there is fleet precedent). `_schedule` becomes: ladder while
nothing found, else 15s. The comment on the throttled restart probe in `Plugin::_onLinkState`
cites `reconnectNow`'s pace and must be reworded.

**Added:** the address field, its validation, the TCP `GetInfo` identify step, the discovery
switch (starting and stopping `Discovery` when it is saved), and a settings page. Saving the page
reconciles at once: removed addresses and, with discovery off, every non-configured player go on
save.

**Untouched:** `_idsFor`, `_liveOf`, `_isSplit`, `_idFor`, `_nameFor`, DHCP follow, the pair re-key
guard, `INSTANCE_TTL` (300s), partial-list player creation on the first reply, `Player::connected`,
the status watchdog, the Restart rows.

**Test pins to replace, not just delete** (`t_plugin.pl`: the 15s idle pin, the `reconnectNow`
poke, the `_linkUpFor` block and the `start` signature; `t_control.pl`: the `reconnectNow` block):

- a round sends **exactly one** datagram, to the multicast group, however many instances are known
- the next round's delay is the same whether links are up or down
- the socket survives a round, and a reply after `LISTEN_TIME` is accepted
- a link drop triggers one probe, and only one
- a dropped link returns within 10s with discovery stopped
- a configured address and a discovery reply with the same `name` give **one id** — the same one
- a configured address is never expired; a removed one goes **on save** unless discovery hears it
- removed then re-added, an address gets back the **same id** it had
- a bad address or a hostname is named and nothing is saved; an empty field saves as off
- discovery off: no socket is opened and no datagram is sent, `probeNow` sends nothing, and every
  player not in the box is removed on save
- discovery off with an empty box is refused, and nothing is saved
- discovery defaults to on, so an upgraded install behaves exactly as before
- `INSTANCE_TTL` stays 300 and removal still needs *both* not-connected and not-heard

The `CLAUDE.md` ledger entries that cite `reconnectNow`, `COLD_PERIOD`, `_linkUpFor` or the unicast
probe are updated in the same change.
