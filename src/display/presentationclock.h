// SPDX-License-Identifier: GPL-3.0-only

#ifndef PRESENTATIONCLOCK_H
#define PRESENTATIONCLOCK_H

// Called by a paced logical tick before composing a frame. A missed deadline
// consumes one slot; spare slots never turn into catch-up draws.
class PresentationClock
{
public:
    static bool limits(int cap, int logicRate, int multiplier) {
        return cap > 0 && logicRate > cap && multiplier == 1;
    }

    bool due(double now, int cap, int logicRate, int multiplier, unsigned comebacks)
    {
        if (!limits(cap, logicRate, multiplier)) {
            reset();
            return true;
        }

        const double interval = 1.0 / cap;
        if (cap != lastCap || comebacks != lastComebacks) {
            lastCap = cap;
            lastComebacks = comebacks;
            next = now + interval;
            return true;
        }

        // Allow for rounding when a logic tick lands on the same deadline.
        constexpr double epsilon = 1e-8;
        if (now + epsilon < next)
            return false;
        const double late = now + epsilon - next;
        if (late >= interval)
            next = now + interval;
        else
            next += interval;
        return true;
    }

    void reset() { lastCap = 0; }

private:
    int lastCap = 0;
    unsigned lastComebacks = 0;
    double next = 0;
};

#endif
