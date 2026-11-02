// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (c) 2025 MC Edition contributors

#include "test.h"

#include "network/lan_discovery.h"
#include "network/socket.h"
#include "util/string.h"

#include <atomic>
#include <chrono>
#include <thread>

/*
	Exercises the whole LAN discovery round trip in-process: a LanAnnouncer
	answers, discover_lan_servers() asks, and we check both the parsed fields and
	the behaviour when nothing is listening.
*/

class TestLanDiscovery : public TestBase
{
public:
	TestLanDiscovery() { TestManager::registerTestModule(this); }
	const char *getName() { return "TestLanDiscovery"; }

	void runTests(IGameDef *gamedef);

	void testRoundTrip();
	void testIgnoresGarbage();
	void testNoServer();
	void testNameWithSpaces();
};

static TestLanDiscovery g_test_instance;

namespace {

// A port unlikely to collide with a real game or another test run.
constexpr u16 TEST_PORT = 30091;

bool wait_until_serving()
{
	// The announcer thread needs a moment before its socket is answering.
	std::this_thread::sleep_for(std::chrono::milliseconds(150));
	return true;
}

} // namespace

void TestLanDiscovery::runTests(IGameDef *gamedef)
{
	TEST(testRoundTrip);
	TEST(testIgnoresGarbage);
	TEST(testNoServer);
	TEST(testNameWithSpaces);
}

void TestLanDiscovery::testRoundTrip()
{
	LanAnnouncer announcer;
	std::atomic<int> queries{0};

	bool started = announcer.start(TEST_PORT, [&queries]() {
		queries++;
		return std::string(" 40000 3 10 Test World");
	});
	UASSERT(started);
	wait_until_serving();

	auto found = discover_lan_servers(TEST_PORT, 500);
	UASSERT(found.size() >= 1);

	const LanServer &srv = found.front();
	UASSERTEQ(u16, srv.port, 40000);
	UASSERTEQ(int, srv.players, 3);
	UASSERTEQ(int, srv.max_players, 10);
	UASSERT(srv.name == "Test World");
	UASSERT(!srv.address.empty());
	UASSERT(queries.load() >= 1);

	announcer.stop();
}

void TestLanDiscovery::testIgnoresGarbage()
{
	LanAnnouncer announcer;
	std::atomic<int> queries{0};
	UASSERT(announcer.start(TEST_PORT, [&queries]() {
		queries++;
		return std::string(" 40001 0 5 Garbage Test");
	}));
	wait_until_serving();

	// Send something that is not a discovery query; it must be ignored.
	{
		UDPSocket s = UDPSocket::Create(Address(u32(0), 0));
		const char junk[] = "HELLO THERE\n";
		s.Send(Address(0x7F000001u, TEST_PORT), junk, (int)strlen(junk));
	}
	std::this_thread::sleep_for(std::chrono::milliseconds(300));

	UASSERTEQ(int, queries.load(), 0);

	// A real query still works afterwards.
	auto found = discover_lan_servers(TEST_PORT, 400);
	UASSERT(found.size() >= 1);
	UASSERT(queries.load() >= 1);

	announcer.stop();
}

void TestLanDiscovery::testNoServer()
{
	// Nothing is listening on this port: the call must return promptly and
	// empty, not hang or throw.
	auto start = std::chrono::steady_clock::now();
	auto found = discover_lan_servers(30099, 200);
	auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
			std::chrono::steady_clock::now() - start).count();

	UASSERTEQ(size_t, found.size(), 0);
	// Generous upper bound; the point is that it terminates.
	UASSERT(elapsed < 3000);
}

void TestLanDiscovery::testNameWithSpaces()
{
	LanAnnouncer announcer;
	UASSERT(announcer.start(TEST_PORT, []() {
		// Colons and many spaces must survive the round trip.
		return std::string(" 40002 1 20 Bob's Co-op World: Part 2");
	}));
	wait_until_serving();

	auto found = discover_lan_servers(TEST_PORT, 500);
	UASSERT(found.size() >= 1);
	UASSERT(found.front().name == "Bob's Co-op World: Part 2");
	UASSERTEQ(int, found.front().max_players, 20);

	announcer.stop();
}
