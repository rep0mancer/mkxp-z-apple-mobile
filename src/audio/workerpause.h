// SPDX-License-Identifier: GPL-3.0-only

#ifndef AUDIOWORKERPAUSE_H
#define AUDIOWORKERPAUSE_H

#include <atomic>
#include <condition_variable>
#include <mutex>

// The source refillers and ME watcher outlive a host pause. Their own stop
// flags must still allow a join while the other workers remain asleep.
class AudioWorkerPause
{
public:
    static AudioWorkerPause &shared() {
        static AudioWorkerPause gate;
        return gate;
    }

    void setPaused(bool value) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            paused.store(value);
        }
        if (!value) changed.notify_all();
    }

    void stop(std::atomic<bool> &stopping) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            stopping.store(true);
        }
        changed.notify_all();
    }

    bool wait(const std::atomic<bool> &stopping) {
        if (!paused.load())
            return !stopping.load();
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [&] { return !paused.load() || stopping.load(); });
        return !stopping.load();
    }

    // Serialize starting an AL source with the host taking its list of
    // playing sources. A late first buffer must not start it during a pause.
    template<class Play>
    void playWhenActive(const std::atomic<bool> &stopping, Play play) {
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [&] { return !paused.load() || stopping.load(); });
        if (!stopping.load()) play();
    }

private:
    std::mutex mutex;
    std::condition_variable changed;
    std::atomic<bool> paused{false};
};

#endif
