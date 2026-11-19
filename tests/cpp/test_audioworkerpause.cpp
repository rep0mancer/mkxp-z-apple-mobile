// SPDX-License-Identifier: GPL-3.0-only

#include "harness.h"
#include "audio/workerpause.h"

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
