// SPDX-License-Identifier: GPL-3.0-only

#ifndef EVENTWAKE_H
#define EVENTWAKE_H

#include <CoreFoundation/CoreFoundation.h>

// CFRunLoopWakeUp alone does not leave a pending event. A signaled source
// survives the gap between checking SDL's queue and entering the run loop.
class EventWake
{
public:
    explicit EventWake(CFRunLoopRef target) : loop(target) {
        CFRetain(loop);
        CFRunLoopSourceContext context{};
        context.perform = [](void *) {};
        source = CFRunLoopSourceCreate(nullptr, 0, &context);
        CFRunLoopAddSource(loop, source, kCFRunLoopDefaultMode);
    }
    EventWake(const EventWake &) = delete;
    EventWake &operator=(const EventWake &) = delete;

    ~EventWake() {
        CFRunLoopSourceInvalidate(source);
        CFRelease(source);
        CFRelease(loop);
    }

    void signal() {
        CFRunLoopSourceSignal(source);
        CFRunLoopWakeUp(loop);
    }

    SInt32 wait(double seconds) {
        return CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, true);
    }

private:
    CFRunLoopRef loop;
    CFRunLoopSourceRef source;
};

#endif
