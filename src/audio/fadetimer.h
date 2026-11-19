// SPDX-License-Identifier: GPL-3.0-only

#ifndef AUDIOFADETIMER_H
#define AUDIOFADETIMER_H

#include <algorithm>

class AudioFadeTimer
{
public:
    AudioFadeTimer(double start = 0, int milliseconds = 0)
        : start(start), duration(milliseconds / 1000.0) {}

    float progress(double activeSeconds) const {
        if (duration <= 0) return 1.0f;
        const double elapsed = (activeSeconds - start) / duration;
        return static_cast<float>(std::max(0.0, std::min(1.0, elapsed)));
    }

private:
    double start;
    double duration;
};

#endif
