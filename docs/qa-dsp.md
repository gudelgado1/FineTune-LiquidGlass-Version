# DSP regression checks

Run the full native suite with `python3 scripts/run-tests.py`. It uses an inert
host and private test storage; it does not start FineTune's capture services.

For additional concurrency and lifetime checks:

```bash
python3 scripts/run-dsp-checks.py --sanitizer thread
python3 scripts/run-dsp-checks.py --sanitizer address
```

The script copies the real DSP/HAL source files and their signal/stress tests
into a small SwiftPM harness. It writes `source-hashes.json` under the build
directory so the source used by a sanitizer run can be verified. Swift Atomics
is pinned to 1.3.1. `--atomics-path PATH` reuses an existing checkout, and
`--build-dir PATH` selects a separate directory for each sanitizer. Xcode 26+
is required. CI runs both checks after the native tests.

`RealtimeSnapshot` has one control writer and one render reader per instance.
The payload contains only scalar values or C pointers. The control-side owner
retains the pointed-to resource. A sequentially consistent hazard publication
and validation pins the snapshot while a buffer is processed; control reclaims
retired snapshots only when they are absent from the hazard. The callback does
not allocate, release resource owners, or lock. This is lock-free, not wait-free.
Do not use this type for multiple readers or let its payload escape the closure.

Biquad delays belong to the render reader. Control resets publish a revision;
the render reader clears delays at the next buffer boundary. AutoEQ's setup and
preamp gain travel in the same snapshot. `isEnabled` is a separate atomic mixer
hint; `process` reads the authoritative snapshot.

New taps receive `TapDSPConfiguration` before IO registration/start. Saved local
EQ, loudness and cached/imported AutoEQ are built at the actual device rate.
If the selected AutoEQ profile is missing from local storage, startup logs that
correction is unavailable and retains the existing asynchronous fetch fallback.
The first buffers cannot include a profile that has not been obtained yet.

HAL reads admitted through `HALExecutor` have four shared worker slots and one
reserved health-probe slot. A timeout keeps its slot until the blocking call
really returns. Saturation fails closed; a daemon that permanently strands all
slots can require restarting FineTune. The liveness sweep waits asynchronously
and revalidates tap identity, route and render clock before acting on a result.

The native capture controller now owns per-IO-proc render contexts and an async
HAL lifecycle. The small SwiftPM harness checks DSP primitives; use the native
host's --sanitizer thread/address checks for controller/lifecycle integration.
Neither replaces physical playback or full UI testing.

Crossfade checks now run in the same sanitizer harness. `CrossfadeState` publishes
phase, progress and saturated counters in one atomic double-word; a phase change
advances a generation, rejecting progress from a preempted older callback. The
payload has 30 generation bits and two 32-bit frame counters. This is intended for
millisecond fades; totalSamples saturates at UInt32.max. A phase/progress update
uses CAS retries and is lock-free, not wait-free.

`DeviceTransitionCoordinator` owns control-side transition tasks. A replacement
cancels and awaits its predecessor, including deferred cleanup. Cancellation of
the caller cancels its task too; obsolete work cannot return success even if it
swallows CancellationError. Crossfade, destructive switching and source refresh
all use this same coordinator. It cannot interrupt a blocked synchronous HAL call.

A secondary must pass the transport settling interval and render at least 2048
frames before the fade. A fade that stops progressing fails into the existing
destructive fallback; timeouts no longer manufacture progress=1. The independent
AutoEQ copy preserves the primary's preamp mode at the new device rate.

Use `--filter SuiteName` with run-dsp-checks.py for a focused regression run.
The capture ownership and completed HAL lifecycle migration are described in
[qa-hal-lifecycle.md](qa-hal-lifecycle.md).
