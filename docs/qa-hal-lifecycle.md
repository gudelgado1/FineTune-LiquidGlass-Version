# Remaining callback ownership and HAL work

Audited 2026-10-31 after the crossfade fixes. This is an implementation direction,
not a claim that these paths have been migrated or tested against a stalled daemon.

## Current evidence

- `ProcessTapController.activate`, `createSecondaryTap` and `performDeviceSwitch`
  still create taps/aggregates, read HAL properties and start IO synchronously on
  the control thread. Crossfade task serialization does not move that work.
- `AudioObjectID.waitUntilReady` checks a wall-clock deadline *between* synchronous
  `isDeviceAlive` reads. If an individual HAL read stalls, that deadline cannot
  interrupt it. It also pumps a nested run loop, allowing control-side reentry.
- `TapResources.destroy` synchronously stops IO, destroys the IO proc, aggregate
  and process tap. It is called by secondary failure/cleanup, destructive switching
  and partial activation cleanup. These remain possible UI blocking paths.
- `destroyAsync` moves teardown off control but has no deadline or global admission
  limit. `invalidateAsync` awaits its completion without a deadline. An indefinitely
  stalled stop can indefinitely delay recovery; dispatching more jobs is not a fix.
- Callback role IDs and CrossfadeState now use explicit atomics, but controller
  gain/mute/health/ramp fields and processor object references remain shared.
  Promotion still uses timed retirement of some objects. That is not a resource
  ownership proof and is outside the new crossfade-state sanitizer coverage.

## Required ownership

A render context belongs to one IO proc for its entire lifetime, including after
promotion. It holds that callback's delay history, ramp and metering state. The
control thread publishes immutable parameters; it does not transfer mutable DSP
history between running callbacks. A generation identifies route intent, and a
separate lifetime identifies the actual IO proc. These are not interchangeable.

A resource owner holds all created HAL IDs until publication succeeds or cleanup
acknowledges their retirement. Cancellation/timeout must not discard IDs or release
a render context while an IO proc may still use it. The stop/destroy acknowledgement,
not a 500ms timer, determines when resource-owned context can be released.

## Migration order (Extra High)

1. Introduce one per-IO-proc render context and move mutable history into it.
   Publish gain/mute/bypass through atomics. Make processor replacement retain
   its owner until the callback reader has finished, as the biquad snapshots do.
2. Define an async resource-lifecycle interface accepting an immutable tap plan.
   A native HAL adapter and a controlled test adapter must use the same interface.
   The native adapter executes blocking calls on bounded workers outside MainActor.
3. Split prepare/configure/start: the HAL worker discovers IDs/rate; control builds
   DSP for that rate; the worker starts the already-prepared IO proc. Each step
   checks route generation before publication. Late completion after cancellation
   retires its own resources and never overwrites the latest route.
4. Give retirement an explicit completion result and deadline. Keep ownership of
   work that timed out; stop admitting new capture work if retirement capacity is
   exhausted. A bound on worker threads alone must not drop cleanup requests/IDs.
5. Migrate engine `ensureTap*`, recovery and shutdown to that interface. Replace
   readiness polling/nested run loops with worker reads bounded from the caller.
   An in-process timeout still cannot cancel blocked kernel work; if hard reclaim
   is required, evaluate process isolation separately.

## Acceptance checks

Use the controlled adapter to hold create/start/stop/destroy at each suspension:
MainActor must remain responsive, pending work must stay bounded, cancellation
must not leak ownership, and a late result must clean itself rather than publish.
Cover partial creation failure at every step and destruction order. Then exercise
the actual callbacks under sanitizers while changing gain, DSP, routing and mute.

Hardware QA must cover rapid device changes, a return to the original route during
warmup, removal of the source/destination, multiple outputs, Bluetooth settle,
sleep/wake and long playback. Unit tests do not verify audible continuity or that
a physical output actually delivers sound.
