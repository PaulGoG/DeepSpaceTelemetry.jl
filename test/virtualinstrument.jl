# VirtualInstrument: the flag payload and external ingestion.

@testset "VirtualInstrument flag series" begin
    start_t = DateTime(2030, 1, 1)
    # One marker inside the third segment, one on the boundary opening the
    # fifth, one before the stream starts.
    markers = [
        TelemetryCore.EventMarker(start_t + Second(150), "inside"),
        TelemetryCore.EventMarker(start_t + Second(240), "boundary"),
        TelemetryCore.EventMarker(start_t - Second(1), "before"),
    ]
    vi = VirtualInstrument.InstrumentState(start_t, 4.0, 60.0, "synthetic", ""; markers)
    segments = [VirtualInstrument.next_segment!(vi) for _ in 1:6]
    @test [s.id for s in segments] == 1:6
    @test [s.timestamp for s in segments] == [start_t + Second(60 * k) for k in 0:5]
    @test all(s -> length(s.data) == 240, segments)
    @test all(s -> eltype(s.data) == Float32, segments)
    # A segment is 1 throughout when its span [epoch, epoch + 60 s) holds a
    # marker and 0 throughout otherwise; a marker on a boundary belongs to the
    # segment it opens.
    @test [unique(s.data) for s in segments] == [[0.0f0], [0.0f0], [1.0f0], [0.0f0], [1.0f0], [0.0f0]]
    @test vi.last_t == start_t + Second(360)

    quiet = VirtualInstrument.InstrumentState(start_t, 4.0, 60.0, "synthetic", "")
    @test all(iszero, VirtualInstrument.next_segment!(quiet).data)

    # The series depends on the content clock alone: an instrument started
    # later, or one whose clock jumped a generation gap, flags the same instants.
    late = VirtualInstrument.InstrumentState(
        start_t + Second(120),
        4.0,
        60.0,
        "synthetic",
        "";
        markers,
    )
    @test VirtualInstrument.next_segment!(late).data == segments[3].data
    jumped = VirtualInstrument.InstrumentState(start_t, 4.0, 60.0, "synthetic", ""; markers)
    jumped.last_t = start_t + Second(240)
    @test all(isone, VirtualInstrument.next_segment!(jumped).data)

    # Sub-second segments advance the content clock exactly.
    fast = VirtualInstrument.InstrumentState(start_t, 10.0, 0.5, "synthetic", "")
    foreach(_ -> VirtualInstrument.next_segment!(fast), 1:3)
    @test fast.last_t == start_t + Millisecond(1500)
    @test TelemetryCore.segment_period(0.07) == Millisecond(70)

    # Not a whole number of milliseconds; less than one sample per segment;
    # unknown source; non-positive rate.
    for (rate, duration, source) in (
        (4.0, 0.0005, "synthetic"),
        (0.01, 60.0, "synthetic"),
        (4.0, 60.0, "analytic"),
        (0.0, 60.0, "synthetic"),
    )
        @test_throws ArgumentError VirtualInstrument.InstrumentState(
            start_t,
            rate,
            duration,
            source,
            "",
        )
    end
end

@testset "VirtualInstrument External" begin
    # Relative external paths resolve against PROJECT_ROOT, not the CWD
    # (the test process runs from test/, exactly the regression condition).
    # The fixture lives in a temporary directory and is passed as a path
    # relative to PROJECT_ROOT, so the real data/ tree stays untouched.
    fixture_dir = mktempdir()
    abs_name = joinpath(fixture_dir, "ext.csv")
    rel_name = relpath(abs_name, TelemetryCore.PROJECT_ROOT)
    try
        CSV.write(abs_name, DataFrame(Amplitude = Float32[1.0, 2.0, 3.0, 4.0]))
        vi_rel = VirtualInstrument.InstrumentState(
            DateTime(2030, 1, 1),
            2.0,
            2.0,
            "external",
            rel_name,
        )
        @test vi_rel.source.samples == Float32[1.0, 2.0, 3.0, 4.0]
    finally
        rm(fixture_dir; recursive = true, force = true)
    end

    # Corner cases: non-numeric / empty external data abort with clean
    # [CONFIG] errors; mid-stream exhaustion pads with zeros and warns once
    mktempdir() do tmp
        txt_csv = joinpath(tmp, "text.csv")
        CSV.write(txt_csv, DataFrame(Amplitude = ["a", "b"]))
        @test_throws ArgumentError VirtualInstrument.InstrumentState(
            DateTime(2030, 1, 1),
            2.0,
            2.0,
            "external",
            txt_csv,
        )

        empty_csv = joinpath(tmp, "empty.csv")
        CSV.write(empty_csv, DataFrame(Amplitude = Float32[]))
        @test_throws ArgumentError VirtualInstrument.InstrumentState(
            DateTime(2030, 1, 1),
            2.0,
            2.0,
            "external",
            empty_csv,
        )

        short_csv = joinpath(tmp, "short.csv")
        CSV.write(short_csv, DataFrame(Amplitude = Float32[1, 2, 3, 4, 5, 6]))
        vi_s = VirtualInstrument.InstrumentState(
            DateTime(2030, 1, 1),
            2.0,
            2.0,
            "external",
            short_csv,
        )
        VirtualInstrument.next_segment!(vi_s)                     # samples 1–4: silent
        seg_pad = @test_logs (:warn,) match_mode=:any VirtualInstrument.next_segment!(vi_s)
        @test seg_pad.data == Float32[5.0, 6.0, 0.0, 0.0]         # 5–6 + zero padding
    end

    mktempdir() do tmp
        csv_path = joinpath(tmp, "ext.csv")
        df = DataFrame(Amplitude = Float32[0.1, 0.2, 0.3, 0.4, 0.5])
        CSV.write(csv_path, df)

        start_t = DateTime(2030, 1, 1)
        vi = VirtualInstrument.InstrumentState(start_t, 2.0, 2.0, "external", csv_path)

        seg1 = VirtualInstrument.next_segment!(vi)
        # Needs 4 samples (2.0 * 2.0). 0.1, 0.2, 0.3, 0.4
        @test length(seg1.data) == 4
        @test seg1.data == Float32[0.1, 0.2, 0.3, 0.4]

        seg2 = VirtualInstrument.next_segment!(vi)
        # Needs 4 samples. 0.5, then 0.0, 0.0, 0.0
        @test length(seg2.data) == 4
        @test seg2.data == Float32[0.5, 0.0, 0.0, 0.0]
    end
end
