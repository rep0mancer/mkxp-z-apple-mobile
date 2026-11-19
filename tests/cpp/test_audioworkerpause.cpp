// SPDX-License-Identifier: GPL-3.0-only

#include "harness.h"
#include "audio/workerpause.h"
#include "audio/fadetimer.h"
#include "util/awayclock.h"

#include <atomic>
#include <chrono>
#include <future>

TEST(paused_audio_worker_resumes_without_polling)
{
    AudioWorkerPause gate;
    std::atomic<bool> stop{false};
    gate.setPaused(true);
    auto work = std::async(std::launch::async, [&] { return gate.wait(stop); });
    CHECK(work.wait_for(std::chrono::milliseconds(15)) == std::future_status::timeout);
    gate.setPaused(false);
    CHECK(work.get());
}

TEST(stopping_one_paused_stream_allows_it_to_join_without_resuming_others)
{
    AudioWorkerPause gate;
    std::atomic<bool> stop{false}, keep{false};
    gate.setPaused(true);
    auto stopping = std::async(std::launch::async, [&] { return gate.wait(stop); });
    auto waiting = std::async(std::launch::async, [&] { return gate.wait(keep); });
    gate.stop(stop);
    const bool joined = stopping.wait_for(std::chrono::seconds(1)) == std::future_status::ready;
    CHECK(joined);
    CHECK(waiting.wait_for(std::chrono::milliseconds(15)) == std::future_status::timeout);
    gate.setPaused(false);
    CHECK(!stopping.get());
    CHECK(waiting.get());
}

TEST(a_source_first_buffer_waits_for_resume_or_its_own_stop)
{
    AudioWorkerPause gate;
    std::atomic<bool> stop{false}, played{false};
    gate.setPaused(true);
    auto start = std::async(std::launch::async, [&] {
        gate.playWhenActive(stop, [&] { played.store(true); });
    });
    CHECK(start.wait_for(std::chrono::milliseconds(15)) == std::future_status::timeout);
    gate.stop(stop);
    const bool stopped = start.wait_for(std::chrono::seconds(1)) == std::future_status::ready;
    gate.setPaused(false);
    start.get();
    CHECK(stopped);
    CHECK(!played.load());
}

TEST(pausing_waits_for_the_current_audio_fade_before_inspecting_sources)
{
    AudioWorkerPause gate;
    std::atomic<bool> stop{false};
    auto step = gate.lockMaintenance(stop);
    auto pause = std::async(std::launch::async, [&] { gate.setPaused(true); });
    CHECK(pause.wait_for(std::chrono::milliseconds(15)) == std::future_status::timeout);
    step.unlock();
    pause.get();
    auto fade = std::async(std::launch::async, [&] {
        return bool(gate.lockMaintenance(stop));
    });
    CHECK(fade.wait_for(std::chrono::milliseconds(15)) == std::future_status::timeout);
    gate.stop(stop);
    const bool joined = fade.wait_for(std::chrono::seconds(1)) == std::future_status::ready;
    gate.setPaused(false);
    CHECK(joined);
    CHECK(!fade.get());
}

TEST(fade_progress_uses_only_active_engine_time)
{
    using Clock = AwayClock::Clock;
    const auto start = Clock::time_point{};
    const auto at = [&](int ms) { return start + std::chrono::milliseconds(ms); };
    AwayClock clock(start);
    AudioFadeTimer fade(clock.seconds(at(0)), 4000);
    CHECK_EQ(0.25f, fade.progress(clock.seconds(at(1000))));
    clock.leave(at(1000));
    CHECK_EQ(0.25f, fade.progress(clock.seconds(at(6000))));
    clock.comeBack(at(6000));
    CHECK_EQ(0.5f, fade.progress(clock.seconds(at(7000))));
    CHECK_EQ(1.0f, fade.progress(clock.seconds(at(10000))));
    CHECK_EQ(1.0f, AudioFadeTimer(1.0, 0).progress(1.0));
}
