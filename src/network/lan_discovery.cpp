// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (c) 2025 MC Edition contributors

#include "network/lan_discovery.h"

#include "debug.h"
#include "log.h"
#include "util/string.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <set>

#ifdef _WIN32
#include <winsock2.h>
#else
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#endif

namespace {

// Make a UDP socket able to send to 255.255.255.255.
bool enable_broadcast(UDPSocket &socket)
{
	int fd = socket.GetHandle();
	if (fd < 0)
		return false;
	int on = 1;
	return setsockopt(fd, SOL_SOCKET, SO_BROADCAST,
			reinterpret_cast<const char *>(&on), sizeof(on)) == 0;
}

std::string printable_address(const Address &addr)
{
	std::string s = addr.serializeString();
	// serializeString() yields "host:port"; we only want the host
	auto pos = s.rfind(':');
	if (pos != std::string::npos)
		s = s.substr(0, pos);
	// strip IPv6 brackets
	if (!s.empty() && s.front() == '[' && s.back() == ']')
		s = s.substr(1, s.size() - 2);
	return s;
}

std::string strip_newlines(std::string s)
{
	s.erase(std::remove(s.begin(), s.end(), '\n'), s.end());
	s.erase(std::remove(s.begin(), s.end(), '\r'), s.end());
	return s;
}

} // namespace

/*
	LanAnnouncer
*/

LanAnnouncer::~LanAnnouncer()
{
	stop();
}

bool LanAnnouncer::start(u16 discovery_port, std::function<std::string()> info_cb)
{
	if (m_running.load())
		return true;

	{
		std::lock_guard<std::mutex> lock(m_cb_mutex);
		m_info_cb = std::move(info_cb);
	}

	try {
		// Bind IPv4 on all interfaces: broadcasts never arrive on IPv6 anyway,
		// and this keeps the socket simple on every platform.
		m_socket = UDPSocket::Create(Address(U32_MAX, discovery_port));
		enable_broadcast(m_socket);
	} catch (const std::exception &e) {
		warningstream << "LAN discovery: cannot bind UDP port " << discovery_port
			<< " (" << e.what() << "); LAN discovery disabled." << std::endl;
		return false;
	}

	m_stop.store(false);
	m_running.store(true);
	m_thread = std::thread(&LanAnnouncer::run, this);

	infostream << "LAN discovery: announcing on UDP port " << discovery_port
		<< std::endl;
	return true;
}

void LanAnnouncer::stop()
{
	m_stop.store(true);
	if (m_thread.joinable())
		m_thread.join();
	m_running.store(false);
	m_socket.Close();
}

void LanAnnouncer::run()
{
	char buf[LAN_DISCOVERY_MAX_PACKET];

	while (!m_stop.load()) {
		Address sender;
		int len = -1;
		try {
			// Short timeout so stop() is responsive.
			if (!m_socket.WaitData(200))
				continue;
			len = m_socket.Receive(sender, buf, sizeof(buf) - 1);
		} catch (const std::exception &e) {
			if (m_stop.load())
				break;
			warningstream << "LAN discovery: receive failed: " << e.what()
				<< std::endl;
			continue;
		}
		if (len <= 0)
			continue;

		buf[len] = '\0';
		std::string_view query(buf, (size_t)len);

		// Tolerate trailing whitespace/CR from other implementations.
		while (!query.empty() && (query.back() == '\n' || query.back() == '\r'
				|| query.back() == ' '))
			query.remove_suffix(1);

		if (query != "LANQUERY 1")
			continue;

		std::string reply = LAN_DISCOVERY_REPLY;
		{
			std::lock_guard<std::mutex> lock(m_cb_mutex);
			if (m_info_cb)
				reply += m_info_cb();
		}
		reply = strip_newlines(reply) + "\n";

		try {
			m_socket.Send(sender, reply.data(), (int)reply.size());
		} catch (const std::exception &e) {
			if (!m_stop.load())
				warningstream << "LAN discovery: reply failed: " << e.what()
					<< std::endl;
		}
	}
}

/*
	Discovery
*/

std::vector<LanServer> discover_lan_servers(u16 discovery_port, int timeout_ms)
{
	std::vector<LanServer> found;
	std::set<std::string> seen;

	UDPSocket socket;
	try {
		// Ephemeral port: we only send and listen for replies.
		socket = UDPSocket::Create(Address(u32(0), 0));
		if (!enable_broadcast(socket)) {
			warningstream << "LAN discovery: cannot enable broadcast; "
				"the network may block discovery." << std::endl;
		}
		socket.setTimeoutMs(50);
	} catch (const std::exception &e) {
		warningstream << "LAN discovery: cannot create socket: " << e.what()
			<< std::endl;
		return found;
	}

	// Send the query to the broadcast address. Some networks (and Android)
	// drop 255.255.255.255, so also cover the common loopback case so a
	// singleplayer host on the same machine is still found.
	const Address broadcast(0xFFFFFFFFu, discovery_port);
	const Address loopback(0x7F000001u, discovery_port);
	const char query[] = LAN_DISCOVERY_QUERY;

	for (const Address &dst : {broadcast, loopback}) {
		try {
			socket.Send(dst, query, (int)strlen(query));
		} catch (const std::exception &e) {
			infostream << "LAN discovery: send to " << dst.serializeString()
				<< " failed: " << e.what() << std::endl;
		}
	}

	auto deadline = std::chrono::steady_clock::now() +
			std::chrono::milliseconds(timeout_ms);
	char buf[LAN_DISCOVERY_MAX_PACKET];

	while (std::chrono::steady_clock::now() < deadline) {
		Address sender;
		int len = -1;
		try {
			if (!socket.WaitData(50))
				continue;
			len = socket.Receive(sender, buf, sizeof(buf) - 1);
		} catch (const std::exception &) {
			continue;
		}
		if (len <= 0)
			continue;
		buf[len] = '\0';
		std::string line(buf, (size_t)len);

		// "LANSERVER 1 <port> <players> <max> <name>"
		if (!str_starts_with(line, LAN_DISCOVERY_REPLY))
			continue;

		std::string rest = line.substr(strlen(LAN_DISCOVERY_REPLY));
		// Drop the single separating space.
		if (!rest.empty() && rest.front() == ' ')
			rest.erase(rest.begin());

		// Field 4 is the free-text name, so split only the first three spaces.
		LanServer srv;
		std::string fields[3];
		size_t cursor = 0;
		bool ok = true;
		for (int i = 0; i < 3; i++) {
			size_t sp = rest.find(' ', cursor);
			if (sp == std::string::npos) { ok = false; break; }
			fields[i] = rest.substr(cursor, sp - cursor);
			cursor = sp + 1;
		}
		if (!ok)
			continue;

		try {
			long port = std::stol(fields[0]);
			long players = std::stol(fields[1]);
			long maxp = std::stol(fields[2]);
			if (port <= 0 || port > 65535)
				continue;
			srv.port = (u16)port;
			srv.players = (int)players;
			srv.max_players = (int)maxp;
		} catch (const std::exception &) {
			continue;
		}
		srv.name = strip_newlines(rest.substr(cursor));
		srv.address = printable_address(sender);

		std::string key = srv.address + ":" + std::to_string(srv.port);
		if (seen.insert(key).second)
			found.push_back(std::move(srv));
	}

	return found;
}
