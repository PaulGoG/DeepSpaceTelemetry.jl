# Masks: batch-state replay from the event logs and its tolerance to pruned and unknown events.

@testset "Exact batch-state reconstruction from event logs" begin
    mktempdir() do tmp
        t0 = DateTime(2035, 1, 1)
        tx = DataFrame(
            SimTime = [t0 - Hour(1), t0 + Minute(1), t0 + Minute(2), t0 + Minute(3)],
            Batch = ["ARCH_batch_1", "LIVE_batch_2", "ARCH_batch_1", "LIVE_batch_2"],
            Event = ["gen", "gen", "tx", "tx"],
        )
        rx = DataFrame(
            SimTime = [t0 + Minute(4), t0 + Minute(5), t0 + Minute(6)],
            Batch = ["ARCH_batch_1", "LIVE_batch_2", "LIVE_batch_2"],
            Event = ["ingested", "retry", "lost"],
            Attempt = [0, 1, 2],
        )
        CSV.write(joinpath(tmp, "events_tx.csv"), tx)
        CSV.write(joinpath(tmp, "events_rx.csv"), rx)

        df = DataFrame(SimTime = [t0, t0 + Minute(2) + Second(30), t0 + Minute(10)])
        states = Masks.reconstruct_batch_states(tmp, df)
        @test length(states) == 3

        # Row 1 (t0): batch 1 pre-populated onboard, batch 2 not yet generated
        @test states[1].onboard_archive == [1]
        @test isempty(states[1].onboard_live) && isempty(states[1].lost)
        # Row 2 (t0+2.5 min): batch 1 on the link, batch 2 onboard (retry events preserve state)
        @test states[2].link_archive == [1]
        @test states[2].onboard_live == [2]
        # Row 3 (t0+10 min): batch 1 grounded, batch 2 permanently lost
        @test states[3].ground_archive == [1]
        @test states[3].lost == [2]
        @test isempty(states[3].link_live) && isempty(states[3].link_archive)

        # The dispatcher picks the exact reconstruction when logs exist
        vis = TelemetryCore.VisibilityModel(Time(8, 0, 0), Second(8 * 3600), "flat")
        @test Masks.batch_states(tmp, df) == states
    end
end

@testset "Event-replay tolerance (pruned + unknown events)" begin
    # A newer run's event log must never abort an older toolchain's replay:
    # `pruned` is state-preserving and unknown event names are skipped with a
    # warning, leaving the delivery state untouched.
    mktempdir() do tmp
        t0 = DateTime(2035, 1, 1, 8, 0, 0)
        tx = DataFrame(
            SimTime = [t0, t0 + Minute(1), t0 + Minute(9)],
            Batch = ["LIVE_batch_1", "LIVE_batch_1", "LIVE_batch_1"],
            Event = ["gen", "tx", "future_tx_event"],
        )
        rx = DataFrame(
            SimTime = [t0 + Minute(2), t0 + Minute(3), t0 + Minute(4)],
            Batch = ["LIVE_batch_1", "LIVE_batch_1", "LIVE_batch_1"],
            Event = ["ingested", "pruned", "future_rx_event"],
            Attempt = [0, 0, 0],
        )
        CSV.write(joinpath(tmp, "events_tx.csv"), tx)
        CSV.write(joinpath(tmp, "events_rx.csv"), rx)
        df = DataFrame(SimTime = [t0 + Minute(30)])
        states = with_logger(NullLogger()) do
            Masks.reconstruct_batch_states(tmp, df)
        end
        @test length(states) == 1
        @test states[1].ground_live == [1]  # delivery state unperturbed
        @test isempty(states[1].lost)
    end

    # Cross-component timestamp skew: emitter and receiver stamp milestones
    # from separate clock reads, so an `ingested` record can carry an earlier
    # timestamp than its own `tx` record at high speed-up. Per-batch causal
    # order must win: the state sequence never regresses.
    mktempdir() do tmp
        t0 = DateTime(2035, 1, 1, 8, 0, 0)
        tx = DataFrame(
            SimTime = [t0, t0 + Minute(5)],
            Batch = ["LIVE_batch_1", "LIVE_batch_1"],
            Event = ["gen", "tx"], # tx recorded AFTER the receiver's ingested
        )
        rx = DataFrame(
            SimTime = [t0 + Minute(3)],
            Batch = ["LIVE_batch_1"],
            Event = ["ingested"],
            Attempt = [0],
        )
        CSV.write(joinpath(tmp, "events_tx.csv"), tx)
        CSV.write(joinpath(tmp, "events_rx.csv"), rx)
        df = DataFrame(
            SimTime = [t0 + Minute(1), t0 + Minute(4), t0 + Minute(6), t0 + Minute(8)],
        )
        states = with_logger(NullLogger()) do
            Masks.reconstruct_batch_states(tmp, df)
        end
        @test states[2].ground_live == [1] # delivered at the ingested record
        @test states[3].ground_live == [1] # the late-stamped tx cannot regress it
        @test states[4].ground_live == [1]
        @test isempty(states[3].link_live)
    end
end
