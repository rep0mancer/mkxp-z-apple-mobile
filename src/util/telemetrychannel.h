// SPDX-License-Identifier: GPL-3.0-only
#ifndef MKXP_TELEMETRYCHANNEL_H
#define MKXP_TELEMETRYCHANNEL_H

#include "app_bridge.h"

#include <atomic>
#include <mutex>

// The VM takes a ticket before sampling. Replacing the host or resetting a
// session invalidates both running producers and work already in flight.
class TelemetryChannel
{
public:
    void set(mkxp_TelemetryCallback callback, void *userdata)
    {
        std::lock_guard<std::mutex> lock(mutex);
        receiver = callback;
        context = userdata;
        renew();
    }

    void reset()
    {
        std::lock_guard<std::mutex> lock(mutex);
        renew();
    }

    uint64_t ticket() const { return active.load(std::memory_order_acquire); }

    void publish(uint64_t ticket, const char *bytes, size_t length)
    {
        if (!ticket || !bytes || !length || length > MKXP_MAX_TELEMETRY_BYTES)
            return;

        // A null setter must retire the old context before it returns. The
        // callback copies the bytes and queues UI work without reentering us.
        std::lock_guard<std::mutex> lock(mutex);
        if (ticket == active.load(std::memory_order_relaxed))
            receiver(bytes, length, context);
    }

private:
    void renew()
    {
        ++generation;
        active.store(receiver ? generation : 0, std::memory_order_release);
    }

    std::mutex mutex;
    mkxp_TelemetryCallback receiver = nullptr;
    void *context = nullptr;
    uint64_t generation = 0;
    std::atomic<uint64_t> active{0};
};

#endif
