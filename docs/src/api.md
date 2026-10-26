# API Reference

```@docs
DeepSpaceTelemetry
```

One page per module:

- [TelemetryCore](api/telemetrycore.md)
- [ChannelEffects](api/channeleffects.md)
- [VirtualInstrument](api/virtualinstrument.md)
- [Emitter](api/emitter.md)
- [Receiver](api/receiver.md)
- [Masks](api/masks.md)
- [MissionFigures](api/missionfigures.md)
- [Metrology](api/metrology.md)
- [Export](api/export.md)
- [Publication](api/publication.md)
- [Supervisor](api/supervisor.md)
- [RunAdapter](api/runadapter.md)
- [Sweeps](api/sweeps.md)
- [PlotTheme](api/plottheme.md)

The public names of `RunAdapter` are versioned with the run-directory contract of the Analysis Interfaces chapter; the other modules document the implementation. `TelemetryCore` and `RunAdapter` live in the reader package, which a consumer may add on its own:

```@docs
DeepSpaceTelemetryReader
DeepSpaceTelemetry.PACKAGE_ROOT
```
