// SPDX-License-Identifier: GPL-3.0-only
#ifndef MKXP_TRANSLATIONCHANNEL_H
#define MKXP_TRANSLATIONCHANNEL_H

#include "app_bridge.h"
#include <chrono>
#include <cstring>
#include <mutex>
#include <string>

// One outstanding dialogue per VM. The game loop only checks this channel
// while a dialogue is waiting. All deadlines use wall time, including in FF.
class TranslationChannel {
    using Clock = std::chrono::steady_clock;
public:
    explicit TranslationChannel(std::chrono::milliseconds timeout = std::chrono::milliseconds(1500))
        : timeout(timeout) {}

    void set(mkxp_TranslationCallback callback, void *userdata) {
        std::lock_guard<std::mutex> lock(mutex);
        receiver = callback;
        context = userdata;
        renew();
    }

    void reset() {
        std::lock_guard<std::mutex> lock(mutex);
        renew();
    }

    void retire(uint64_t ticket) {
        std::lock_guard<std::mutex> lock(mutex);
        if (ticket && ticket == generation)
            renew();
    }

    uint64_t ticket() {
        std::lock_guard<std::mutex> lock(mutex);
        return receiver ? generation : 0;
    }

    uint64_t start(uint64_t ticket, const char *bytes, size_t length) {
        if (!valid(bytes, length))
            return 0;
        std::lock_guard<std::mutex> lock(mutex);
        auto now = Clock::now();
        if (!receiver || ticket != generation || (current && now < deadline))
            return 0;
        answer.clear();
        ready = false;
        current = ++serial;
        deadline = now + timeout;
        // Setter/reset must wait until this borrowed context has returned.
        receiver(current, bytes, length, context);
        return current;
    }

    void complete(uint64_t id, const char *bytes, size_t length) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!id || id != current || ready || Clock::now() >= deadline)
            return;
        if (valid(bytes, length))
            answer.assign(bytes, length);
        ready = true;
    }

    int poll(uint64_t ticket, uint64_t id, char *out, size_t capacity) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!receiver || ticket != generation || !id || id != current)
            return -1;
        if (!ready && Clock::now() < deadline)
            return 0;
        current = 0;
        if (answer.empty() || !out || answer.size() > capacity)
            return -1;
        std::memcpy(out, answer.data(), answer.size());
        return static_cast<int>(answer.size());
    }
private:
    void renew() { ++generation; current = 0; answer.clear(); }
    static bool valid(const char *bytes, size_t length) {
        if (!bytes || !length || length > MKXP_MAX_TRANSLATION_BYTES)
            return false;
        const unsigned char *p = reinterpret_cast<const unsigned char *>(bytes);
        const unsigned char *end = p + length;
        while (p < end) {
            unsigned int first = *p++;
            if (first < 0x80) continue;
            if (first < 0xc2 || first > 0xf4) return false;
            int extra = first < 0xe0 ? 1 : first < 0xf0 ? 2 : 3;
            if (end - p < extra) return false;
            // Exclude overlong forms, UTF-16 surrogates, and values above U+10FFFF.
            if ((first == 0xe0 && *p < 0xa0) || (first == 0xed && *p >= 0xa0) ||
                (first == 0xf0 && *p < 0x90) || (first == 0xf4 && *p >= 0x90)) return false;
            while (extra-- > 0)
                if ((*p++ & 0xc0) != 0x80) return false;
        }
        return true;
    }
    std::mutex mutex;
    mkxp_TranslationCallback receiver = nullptr;
    void *context = nullptr;
    uint64_t generation = 0, serial = 0, current = 0;
    const std::chrono::milliseconds timeout;
    Clock::time_point deadline;
    bool ready = false;
    std::string answer;
};
#endif
