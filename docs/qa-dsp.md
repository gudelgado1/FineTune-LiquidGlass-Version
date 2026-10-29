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

These checks do not certify the entire audio pipeline. `ProcessTapController`
still has shared scalar/reference fields, crossfade transitions, and timed
retirement of some processor objects outside BiquadProcessor. Other paths still
make synchronous HAL calls. Hardware QA must cover playback, mute, device changes,
sleep/wake, multi-output, long sessions and pressure before a release.
