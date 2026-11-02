# LAN multiplayer

Luanti has always been able to host and join games over a network, but it had no
way to *find* them: joining meant typing an IP address by hand, and there was no
equivalent of Minecraft's automatic "LAN World" list. This adds that.

## How it works

A tiny UDP protocol, deliberately simple enough to debug with `netcat`:

```
client -> 255.255.255.255:30001   "LANQUERY 1\n"
server -> client                  "LANSERVER 1 <game port> <players> <max> <name>\n"
```

* The name is last and free text, so it can contain spaces and colons.
* The game port is the port clients actually connect to on (normally 30000).
* Anything that is not exactly `LANQUERY 1` is ignored, so unrelated traffic on
  port 30001 cannot trigger a reply or leak the server's details.

No mDNS or zeroconf: that would mean a new dependency on every platform,
including Android. A few bytes of UDP is plenty for a LAN and builds nowhere
extra.

## Using it

**Host:** nothing to do. Serving a world announces it automatically.

**Join:** `Join Game` tab → **Scan LAN**. The scan blocks for about a second
(`lan_discovery_timeout_ms`, default 1200) while replies arrive, then:

* one game found → its address and port are filled into the form;
* several → the busiest is filled in and the rest are listed in a message.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `lan_discovery_announce` | `true` | Answer discovery queries on the LAN |
| `lan_discovery_port` | `30001` | UDP port used for discovery |
| `lan_discovery_timeout_ms` | `1200` | How long a scan waits for replies |

Turn `lan_discovery_announce` off if you do not want the machine advertising
itself on a shared network.

## Files

| File | Contents |
|---|---|
| `src/network/lan_discovery.h/.cpp` | Protocol, `LanAnnouncer`, `discover_lan_servers()` |
| `src/server.cpp` | Starts/stops the announcer, builds the advertised info per query |
| `src/script/lua_api/l_mainmenu.cpp` | `core.get_lan_servers()` for the main menu |
| `builtin/mainmenu/tab_online.lua` | The **Scan LAN** button |
| `src/unittest/test_lan_discovery.cpp` | Round-trip tests |

## Tests

`src/unittest/test_lan_discovery.cpp` starts a real `LanAnnouncer` in-process and
checks the whole round trip, covering:

* a normal announce/reply with all fields parsed correctly;
* that junk packets are ignored and do not increment the query counter;
* that scanning a port with nothing listening returns empty and terminates
  promptly instead of hanging;
* that names containing spaces and colons survive intact.

Run them with:

```sh
./bin/luanti --run-unittests --test-module TestLanDiscovery
```

## Limits worth knowing

* **Broadcast only.** Discovery stays inside one subnet. It will not find a
  friend across the internet — use port forwarding or a VPN for that.
* **Some networks filter broadcasts.** Managed Wi-Fi (guest networks, corporate
  APs with client isolation) often drops 255.255.255.255. The scan also queries
  loopback so a locally hosted world is still found, but two devices on a locked-
  down network may not see each other. Typing the IP still works.
* **No automatic port forwarding.** This finds games; it does not make them
  reachable from outside the network.
