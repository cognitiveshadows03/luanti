// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (c) 2025 MC Edition contributors

#pragma once

#include "irrlichttypes.h"
#include "network/socket.h"
#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

/*
	LAN server discovery.

	Luanti has no way to find a game running on the same network: every join
	needs a typed IP address. This adds a small, self-contained discovery
	protocol on top of UDP so a client can list the worlds on its LAN.

	Protocol (plain text, one datagram each, designed to be debuggable by hand
	with netcat):

		client -> broadcast:30001   "LANQUERY 1\n"
		server -> client            "LANSERVER 1 <port> <players> <max> <name>\n"

	The trailing field is free text (the world/server name) and is always last
	so it can contain spaces. Newlines are stripped from the name.

	Deliberately not mDNS/zeroconf: it needs no extra library, works on every
	platform Luanti supports including Android, and a handful of bytes is plenty
	for a LAN.
*/

#define LAN_DISCOVERY_QUERY "LANQUERY 1\n"
#define LAN_DISCOVERY_REPLY "LANSERVER 1"
// Kept small so a stray packet cannot make us allocate wildly.
#define LAN_DISCOVERY_MAX_PACKET 1024

struct LanServer
{
	std::string address;   // printable IP, e.g. "192.168.1.42"
	u16 port = 0;          // the game port, not the discovery port
	std::string name;
	int players = 0;
	int max_players = 0;
};

/*
	Announces this server on the local network.

	Runs a small thread that answers discovery queries. The advertised info is
	produced by a callback on each query, so player counts are always current
	without any extra bookkeeping.
*/
class LanAnnouncer
{
public:
	LanAnnouncer() = default;
	~LanAnnouncer();

	LanAnnouncer(const LanAnnouncer &) = delete;
	LanAnnouncer &operator=(const LanAnnouncer &) = delete;

	/// Start answering queries on `discovery_port`.
	/// @param info_cb returns the fields to advertise:
	///        " <port> <players> <max_players> <name>" (leading space included)
	/// @return false if the socket could not be bound (e.g. port in use)
	bool start(u16 discovery_port, std::function<std::string()> info_cb);
	void stop();
	bool isRunning() const { return m_running.load(); }

private:
	void run();

	UDPSocket m_socket;
	std::thread m_thread;
	std::atomic<bool> m_stop{false};
	std::atomic<bool> m_running{false};
	std::mutex m_cb_mutex;
	std::function<std::string()> m_info_cb;
};

/*
	Ask the local network for running servers.

	Blocks for up to `timeout_ms`, so call it from a worker thread or accept a
	short main-menu stall (the default is about a second).
*/
std::vector<LanServer> discover_lan_servers(u16 discovery_port, int timeout_ms);
