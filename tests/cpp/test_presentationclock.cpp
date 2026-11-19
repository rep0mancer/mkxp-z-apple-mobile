// SPDX-License-Identifier: GPL-3.0-only

#include "harness.h"
#include "display/presentationclock.h"

TEST(presentationclock_preserves_all_sixty_logic_ticks_and_selects_forty_draws)
{
    PresentationClock clock;
    int draws = 0;
    for (int i = 0; i < 60; ++i)
        draws += clock.due(i / 60.0, 40, 60, 1, 0);
    CHECK(draws == 40);
}

TEST(presentationclock_preserves_lower_game_rates_and_slow_frames)
{
    PresentationClock clock;
    PresentationClock overloaded;
    for (int tick = 0; tick < 120; ++tick) {
        CHECK(clock.due(tick / 30.0, 60, 30, 1, 0));
        CHECK(overloaded.due(tick / 30.0, 40, 60, 1, 0));
    }
}

TEST(presentationclock_starts_fresh_on_resume_and_fast_forward_changes)
{
    PresentationClock clock;
    CHECK(clock.due(0, 40, 60, 1, 0));
    CHECK(!clock.due(0.01, 40, 60, 1, 0));
    CHECK(clock.due(0.011, 40, 60, 1, 1));
    CHECK(!clock.due(0.012, 40, 60, 1, 1));
    CHECK(clock.due(0.013, 40, 60, 2, 1));
    CHECK(clock.due(0.014, 40, 60, 1, 1));
    CHECK(clock.due(0.015, 60, 120, 1, 1));
}

TEST(presentationclock_keeps_native_uncapped_pacing_and_no_catchup_burst)
{
    PresentationClock clock;
    CHECK(clock.due(0, 40, 0, 1, 0));
    CHECK(clock.due(0.001, 40, 0, 1, 0));
    CHECK(clock.due(0.002, 0, 120, 1, 0));
    CHECK(clock.due(0.003, 40, 120, 1, 0));
    CHECK(clock.due(3.003, 40, 120, 1, 0));
    CHECK(!clock.due(3.004, 40, 120, 1, 0));
}
