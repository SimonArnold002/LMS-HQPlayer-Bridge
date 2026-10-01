# Discovery: find it, add it, let the link keep it

**Status: BUILT 2026-09-27, uncommitted, not verified live.** What was built, and its tests: CLAUDE.md, `DISCOVERY FINDS, THE LINK KEEPS`. Restarted from scratch 2026-09-27; the previous draft was discarded. Sections 4.5-4.7, 5 and 7 were rewritten the same day to Simon's rules as he gave them while it was built (two modes, off is off, a new address must answer), replacing the first draft's text rather than patching it.

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

### 4.5 Two modes, never both

Simon, 2026-09-27:

> *"the option to turn off auto discovery and rely purely on IP input needs to be an option."*
>
> *"only allow manual ip addresses when auto is turned off. When its turned off clean the records,
> we should not be having both active at same time."*
>
> *"when auto discovery is off all players are removed, same happens when we have players and go
> back to autodiscovery that was the entire premise of this addition. It should not discover or
> add any player without an IP added when in manual mode and vice versa when in auto discovery."*

One setting, **Find HQPlayer**, with two options. Exactly one is in force at a time:

| | **Automatically** | **Only at the addresses below** |
|---|---|---|
| where players come from | discovery replies only | the typed addresses only |
| UDP | one multicast probe a round (§4.1) | **none**: no socket, no probe, `probeNow` does nothing, nothing in any HQPlayer's log |
| the address box | not used; greyed out on the page, and **cleared** when saved | the whole list |
| an empty box means | nothing (it is always empty) | **no players**, and nothing is found until an address is typed. Never refused, never a fallback to discovering |
| an HQPlayer whose address changes | followed (§5) | not followed: its link drops, and the user replaces the address |

**Switching cleans out the other mode, at once, connected or not:**

- **Automatic → addresses only:** every player whose address is not in the box is removed on save,
  and discovery's table is dropped. With an empty box, that is every player. A player at an address
  that IS typed stays, named from its own player, with no second connection opened to it.
- **Addresses only → automatic:** the box is cleared (Simon's pick of three: clear it, rather than
  refuse the save or keep it unused), every typed player is removed on save, and discovery finds
  again whatever it can reach.

Either way a player's settings stay under its id, so one that comes back, from either mode, is the
**same** player with its prefs and playlist (§4.3).

**The default mode** lives in one place, `Addresses::AUTO_DEFAULT`, and it is **automatic**, so a
new install, or an update from a release without this setting, behaves exactly as before (the
test builds 1.0.30-1.0.33 had it off, Simon's call for testing). **An update never overrides a
user's choice:** the default only fills a setting that has never been stored, the settings page
always stores an explicit choice, and nothing else in the plugin writes it.

### 4.6 The addresses mode: one box

Simon: *"a box to enter and save it to our config, not multiple boxes for each player"* and
*"devices or networks change so a user needs the ability to remove it and add it again."*

- **One field**, several addresses separated by commas, spaces, semicolons or new lines. **IP
  addresses only** (decision 1). A bad entry is **named** and nothing is saved, not even the good
  ones.
- **A new address is saved only if HQPlayer answers there.** Simon: *"we stipulate HQP must be up
  and running to establish a valid connection"*, the same shape as LBF's API-token check. On save,
  each address the save ADDS is asked `<GetInfo/>` over TCP, and the page waits (up to 8s) for the
  answers. If any one does not answer, the whole save is refused and that address is named. If all
  answer, the page names the HQPlayer that answered at each. An address already saved is not
  re-checked, so one HQPlayer being off never blocks editing the others. An address whose player
  is already connected counts as answered: that link is the valid connection.
- **One connection per new address.** The page's answer is handed on, so applying the save does
  not ask the same HQPlayer again.
- **Keyed by HQPlayer's name**, which `GetInfo` returns exactly as discovery does (§4.3), so a
  typed address gets the same id discovery would have given it.
- **A typed address never expires.** Its player stays for as long as the address is in the box,
  and leaves Material the instant its link drops, as every player does. While there is no player
  (HQPlayer off since the save), it is tried over TCP once a round (15s). A dead host costs a TCP
  attempt, not a line in anyone's HQPlayer log.
- **Removing and re-adding.** Delete an address and save: its player goes **at once**. Add it back
  and save: the **same** player returns. HQPlayer moved: replace the old address with the new one,
  and the same player follows.

### 4.7 The settings page

It brings back `Settings.pm` (the old one went in 0.2.60-0.2.76, when the live view replaced it),
built to the fleet's rules:

- **The mode is a radio group to LBF's spec**, a bug that has caught the fleet more than once:
  each option wrapped in a `<label>`, one per line with `<br>`, never a `<select>`, and EXACTLY ONE
  option checked in every state, decided in Perl rather than by matching a stored value in the
  template.
- Every field is `pref_<name>`. A hidden sentinel field means a partial POST changes nothing.
- Material never shows `warning`, so every result (a refusal and its reason, or the names that
  answered) is drawn in the page itself.
- The page calls nothing in `Plugin.pm`. A save takes effect through the prefs' change handler,
  applied once both prefs are stored.
- Linked from LMS's plugin list (`optionsURL`) and from a Settings row in the Apps feed.

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
| multicast unreliable, instance **not** connected | kept while unicast answers | removed after 300s — **switch to addresses only and type its address** | changed |
| multicast blocked entirely | never found | **switch to addresses only and type its address** | better |
| HQPlayer on two active interfaces | permanent split into two players (declined scope) | the unused address ages out after 300s and they collapse to the plain id | changed, unsupported config |

The two "changed" rows are the only departures, and both are on configurations the address box
exists for or that are already declined as scope.

New cases, which have no "today":

| what happens | after |
|---|---|
| switched to **addresses only**, box empty | every player goes on save; nothing is found until an address is typed |
| switched to **addresses only**, box filled | every player not in the box goes on save; a connected one at a typed address stays |
| switched back to **automatically** | the box is cleared, every typed player goes on save, discovery finds again what it can reach |
| a new address is typed, HQPlayer running there | saved, and the page names the HQPlayer that answered |
| a new address is typed, nothing answers | refused, the address named, nothing saved |
| an address is removed from the box | its player goes on save |
| the same address is added back | the **same** player returns with its settings |
| HQPlayer's address changes, **automatically** | followed, as today |
| HQPlayer's address changes, **addresses only** | its link drops; replace the address in the box and the same player returns |

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
   (Simon, 2026-09-27): §4.6 and §4.5.
4. **Two modes, never both, and off is off** (Simon, 2026-09-27): §4.5. This replaced the first
   draft's single table, where a typed address could also be discovered and "off with an empty box"
   was refused on save. Both are gone: no address is ever in both modes, and an empty box with
   discovery off means no players.
5. **Switching back to automatic clears the box** (Simon's pick of three, 2026-09-27): §4.5.
6. **A new address must answer before it is saved** (Simon, 2026-09-27): §4.6.
7. **The mode is a radio group to the fleet's spec** (Simon, 2026-09-27): §4.7.
8. **Default mode: automatic; an update never overrides a user's choice** (Simon, 2026-09-27,
   after off-by-default test builds): §4.5.

## 8. What changes in the code

**Deleted:** the unicast loop in `Discovery::_probe`; `_settled`; `COLD_PERIOD` as a link-state
pace; the per-round socket open/close; `Plugin::_linkUpFor` and its argument to `Discovery->start`;
`Control::reconnectNow` and its call in `_onInstances`.

**Changed:** `BACKOFF_MAX` 60 → 10. `Discovery` gains `probeNow`, called on a link drop (Platin
Bridge's `Discovery.pm` has one, so there is fleet precedent). `_schedule` becomes: ladder while
nothing found, else 15s. The comment on the throttled restart probe in `Plugin::_onLinkState`
cites `reconnectNow`'s pace and must be reworded.

**Added:** `Addresses.pm` (the box: parsing, keying by `GetInfo` name, the once-a-round retry);
`Control::identify` (one connection, one `<GetInfo/>`, closed); `Settings.pm` and its template
(the radio group, the box, the connection check on save); the mode switch, which starts and stops
`Discovery`'s UDP and cleans out the other mode's players on save (§4.5).

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
- a typed address gets the same id discovery gives the same `name`
- a typed address is never expired; a removed one goes **on save**; re-added, it is the **same id**
- a bad address or a hostname is named and nothing is saved
- a new address is saved only if HQPlayer answers; one that does not refuses the whole save and is
  named; an address already saved is not re-checked; a connected one opens no second connection
- automatically: the box is never used, and a save clears it; switching on removes every typed
  player
- addresses only: no socket, no datagram, `probeNow` sends nothing; switching off removes every
  player not in the box; an EMPTY box saves and leaves no players, and nothing is ever found
- the radio group: label-wrapped, `<br>`-separated, no `<select>`, exactly one checked in every
  stored state
- the default is `Addresses::AUTO_DEFAULT`, pinned ON; a stored OFF starts with no socket and no
  probe; nothing in the plugin writes either setting except the settings page
- `INSTANCE_TTL` stays 300 and removal still needs *both* not-connected and not-heard

The `CLAUDE.md` ledger entries that cite `reconnectNow`, `COLD_PERIOD`, `_linkUpFor` or the unicast
probe are updated in the same change.
