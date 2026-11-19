// SPDX-License-Identifier: GPL-3.0-only
#include "harness.h"
#include "util/telemetrychannel.h"

#include <chrono>
#include <condition_variable>
#include <future>
#include <string>
#include <thread>

namespace {
void collect(const char *json, size_t length, void *context)
{
    static_cast<std::string *>(context)->assign(json, length);
}
}

TEST(telemetry_rotates_session_and_receiver_tickets)
{
    TelemetryChannel channel;
    std::string first, second;
    CHECK(channel.ticket() == 0);
    channel.set(collect, &first);
    auto initial = channel.ticket();
    channel.publish(initial, "test!", 4);
    CHECK(first == "test");
    channel.reset();
    CHECK(initial != channel.ticket());
    channel.publish(initial, "old", 3);
    CHECK(first == "test");
    channel.set(collect, &second);
    channel.publish(initial, "old", 3);
    CHECK(second.empty());
    auto active = channel.ticket();
    channel.publish(active, "new", 3);
    CHECK(second == "new");
    channel.set(nullptr, nullptr);
    channel.publish(active, "old", 3);
    CHECK(second == "new");
    CHECK(channel.ticket() == 0);
}

TEST(telemetry_limits_the_borrowed_payload)
{
    TelemetryChannel channel;
    std::string out, big(MKXP_MAX_TELEMETRY_BYTES + 1, 'x');
    channel.set(collect, &out);
    channel.publish(channel.ticket(), big.data(), big.size());
    channel.publish(channel.ticket(), nullptr, 5);
    channel.publish(channel.ticket(), big.data(), 0);
    CHECK(out.empty());
    channel.publish(channel.ticket(), big.data(), MKXP_MAX_TELEMETRY_BYTES);
    CHECK(out.size() == MKXP_MAX_TELEMETRY_BYTES);
}

TEST(telemetry_unsubscribe_waits_for_a_borrowed_context_to_return)
{
    struct Delivery {
        std::mutex mutex;
        std::condition_variable condition;
        bool entered = false;
        bool release = false;
        bool finished = false;
    } delivery;

    TelemetryChannel channel;
    channel.set([](const char *, size_t, void *context) {
        auto &d = *static_cast<Delivery *>(context);
        std::unique_lock<std::mutex> lock(d.mutex);
        d.entered = true;
        d.condition.notify_all();
        d.condition.wait(lock, [&] { return d.release; });
        d.finished = true;
    }, &delivery);
    std::thread vm([&] { channel.publish(channel.ticket(), "{}", 2); });
    {
        std::unique_lock<std::mutex> lock(delivery.mutex);
        delivery.condition.wait(lock, [&] { return delivery.entered; });
    }
    std::promise<void> started;
    auto unsubscribed = std::async(std::launch::async, [&] {
        started.set_value();
        channel.set(nullptr, nullptr);
    });
    started.get_future().wait();
    bool stillDelivering = unsubscribed.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout;
    {
        std::lock_guard<std::mutex> lock(delivery.mutex);
        delivery.release = true;
    }
    delivery.condition.notify_all();
    unsubscribed.get();
    vm.join();
    CHECK(stillDelivering);
    CHECK(delivery.finished);
    CHECK(channel.ticket() == 0);
}
