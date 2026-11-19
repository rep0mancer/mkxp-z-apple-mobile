// SPDX-License-Identifier: GPL-3.0-only

#if defined(__APPLE__)
#include "harness.h"
#include "util/eventwake.h"
#include <chrono>
#include <thread>

TEST(eventwake_remembers_an_sdl_event_queued_before_wait)
{
    EventWake wake(CFRunLoopGetCurrent());
    wake.signal();
    CHECK(wake.wait(0.2) == kCFRunLoopRunHandledSource);
}

TEST(eventwake_wakes_a_blocked_run_loop_from_an_input_thread)
{
    EventWake wake(CFRunLoopGetCurrent());
    std::thread input([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        wake.signal();
    });
    CHECK(wake.wait(1.0) == kCFRunLoopRunHandledSource);
    input.join();
}
#endif
