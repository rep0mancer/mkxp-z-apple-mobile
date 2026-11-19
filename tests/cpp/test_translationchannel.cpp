// SPDX-License-Identifier: GPL-3.0-only
#include "harness.h"
#include "util/translationchannel.h"

#include <condition_variable>
#include <future>
#include <thread>

namespace {
struct Received {
    uint64_t id = 0;
    std::string input;
    static void copy(uint64_t id, const char *data, size_t size, void *ctx) {
        auto &r = *static_cast<Received *>(ctx);
        r.id = id;
        r.input.assign(data, size);
    }
};
}

TEST(translation_round_trip_emits_once_and_replies_only_to_current_request)
{
    TranslationChannel channel;
    Received receiver;
    std::string line = "¡Hola!\x1f" "¿Qué tal?";
    std::string result = "Hallo!\x1f" "Wie geht’s?";
    char out[64];
    CHECK(channel.ticket() == 0);
    CHECK(channel.start(0, line.data(), line.size()) == 0);
    channel.set(Received::copy, &receiver);
    auto ticket = channel.ticket();
    auto id = channel.start(ticket, line.data(), line.size());
    CHECK(id != 0);
    CHECK(receiver.id == id);
    CHECK(receiver.input == line);
    CHECK(channel.start(ticket, "nested", 6) == 0);
    channel.complete(id + 1, "late", 4);
    CHECK(channel.poll(ticket, id, out, sizeof(out)) == 0);
    channel.complete(id, result.data(), result.size());
    channel.complete(id, "duplicate", 9);
    CHECK(channel.poll(ticket, id, out, sizeof(out)) == static_cast<int>(result.size()));
    CHECK(std::string(out, result.size()) == result);
    CHECK(channel.poll(ticket, id, out, sizeof(out)) == -1);
}

TEST(translation_reset_or_new_receiver_retires_inflight_work)
{
    TranslationChannel channel;
    Received a, b;
    char out[4];
    channel.set(Received::copy, &a);
    auto old = channel.ticket();
    auto id = channel.start(old, "a", 1);
    channel.reset();
    CHECK(channel.start(old, "old", 3) == 0);
    auto vm = channel.ticket();
    auto next = channel.start(vm, "b", 1);
    channel.complete(id, "old", 3);
    CHECK(channel.poll(vm, next, out, sizeof(out)) == 0);
    channel.set(Received::copy, &b);
    channel.retire(vm);
    auto current = channel.ticket();
    auto live = channel.start(current, "new", 3);
    CHECK(b.input == "new");
    CHECK(next != live);
    CHECK(channel.poll(vm, next, out, sizeof(out)) == -1);
    channel.complete(next, "old", 3);
    CHECK(channel.poll(current, live, out, sizeof(out)) == 0);
    channel.retire(current);
    CHECK(channel.poll(current, live, out, sizeof(out)) == -1);
    channel.set(nullptr, nullptr);
    CHECK(channel.ticket() == 0);
}

TEST(translation_enforces_size_utf8_and_terminal_failure)
{
    TranslationChannel channel;
    Received receiver;
    channel.set(Received::copy, &receiver);
    auto vm = channel.ticket();
    std::string big(MKXP_MAX_TRANSLATION_BYTES + 1, 'x');
    char out[10];
    CHECK(channel.start(vm, nullptr, 1) == 0);
    CHECK(channel.start(vm, "x", 0) == 0);
    CHECK(channel.start(vm, big.data(), big.size()) == 0);
    CHECK(channel.start(vm, "\xc0\x80", 2) == 0);
    CHECK(channel.start(vm, "\xed\xa0\x80", 3) == 0);
    CHECK(channel.start(vm, "\xe2\x82", 2) == 0);
    CHECK(channel.start(vm, "\xf4\x90\x80\x80", 4) == 0);
    auto id = channel.start(vm, big.data(), MKXP_MAX_TRANSLATION_BYTES);
    CHECK(id != 0);
    channel.complete(id, big.data(), big.size());
    CHECK(channel.poll(vm, id, out, sizeof(out)) == -1);
    id = channel.start(vm, "c", 1);
    channel.complete(id, nullptr, 0);
    CHECK(channel.poll(vm, id, out, sizeof(out)) == -1);
    id = channel.start(vm, "d", 1);
    channel.complete(id, "\xc2\x41", 2);
    CHECK(channel.poll(vm, id, out, sizeof(out)) == -1);
}

TEST(translation_late_reply_expires_and_an_abandoned_request_can_be_replaced)
{
    TranslationChannel channel(std::chrono::milliseconds(2));
    Received r;
    char out[1];
    channel.set(Received::copy, &r);
    auto t = channel.ticket();
    auto expired = channel.start(t, "a", 1);
    std::this_thread::sleep_for(std::chrono::milliseconds(8));
    channel.complete(expired, "z", 1);
    CHECK(channel.poll(t, expired, out, sizeof(out)) == -1);
    auto abandoned = channel.start(t, "b", 1);
    std::this_thread::sleep_for(std::chrono::milliseconds(8));
    auto current = channel.start(t, "c", 1);
    CHECK(current && current != abandoned);
    channel.complete(abandoned, "b", 1);
    CHECK(channel.poll(t, abandoned, out, sizeof(out)) == -1);
}

TEST(translation_unsubscribing_waits_for_borrowed_context)
{
    struct Delivery {
        std::promise<void> entered;
        std::promise<void> release;
    } delivery;
    TranslationChannel channel;
    channel.set([](uint64_t, const char *, size_t, void *context) {
        auto &d = *static_cast<Delivery *>(context);
        d.entered.set_value();
        d.release.get_future().wait();
    }, &delivery);
    auto t = channel.ticket();
    auto publish = std::async(std::launch::async, [&] { return channel.start(t, "a", 1); });
    delivery.entered.get_future().wait();
    auto retire = std::async(std::launch::async, [&] { channel.set(nullptr, nullptr); });
    CHECK(retire.wait_for(std::chrono::milliseconds(4)) == std::future_status::timeout);
    delivery.release.set_value();
    CHECK(publish.get() != 0);
    retire.get();
    CHECK(channel.ticket() == 0);
}
