# Capture lifecycle and render ownership

Implemented in the Extra High migration on 2026-10-31. Final hardware QA and CI
execution remain separate follow-up work; the regression checks here validate the
implementation and its failure contracts without opening physical audio devices.

## Render

Every IO proc captures one TapRenderContext for its whole lifetime. Promotion
changes its atomic role; it never moves delay history, ramp or meter state to
another running proc. MainActor owns ProcessTapController and never performs
rendering in production. DSP/math types explicitly opt out of default UI actor
isolation. Render-visible parameters and meters use snapshots/atomics.

The replaceable leveler is pinned through RealtimeSnapshot with
keepLastReadAlive=true. Its last rendered snapshot stays alive until the NEXT
callback entry (or context destruction after IO-proc retirement). This keeps a
Swift temporary reference from becoming the last owner on the render thread.
Only one leveler snapshot read occurs per callback. Unread retired snapshots can
be reclaimed immediately; a stalled reader retains at most its pinned snapshot
plus the current snapshot. Biquad C setups keep their existing hazard lifetime.

## Prepare, configure, start

TapHALAdapting defines the worker-facing lifecycle. NativeTapHALAdapter owns the
partial resource ledger; TapHALOperations is the internal seam for failing each
native step. Preparation creates tap/aggregate and reads readiness, format,
preferred channels and transport on a worker. Control builds DSP at that rate,
using the latest gain/settings. A worker then installs and starts the prepared IO
proc. No native C HAL calls or nested HAL run loops remain in the controller.

OwnedHALExecutor admits four worker jobs. A timed-out/cancelled job owns its result
until it returns; discard handles late success, failure and admission rejection.
An in-progress start cannot race destruction. TapLifecycleAdmission also bounds
prepare/configure/start transactions, asynchronously queuing activation bursts.

The native callback directly invokes its captured context (nil dispatch queue).
Apple documents both direct invocation with nil and retention of the copied block
until matching IO-proc destruction:
[AudioDeviceCreateIOProcIDWithBlock](https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock(_:_:_:_:)).

## Retirement

Live leases retire on explicit invalidation and on owner destruction.
HALRetirementQueue has two serial worker queues. Cleanup requests are never
dropped. Its closure owns resource IDs and context until successful removal.
Teardown is ordered: stop/remove IO proc, remove aggregate, remove process tap.
If any required removal fails, remaining IDs/context are quarantined for retry.
Already-removed IDs are cleared so a retry resumes at the failing step.

Each wait has a deadline; timeout returns to the caller but does not release the
resource. Overdue cleanup, quarantine or a backlog of 16 stops new capture
admission. A shutdown can enqueue more existing resources than that threshold;
the threshold gates new capture, not ownership of cleanup already owed.
Listener removal on stop also uses this retirement queue. Old monitor callbacks
are rejected by lifetime tokens after stop/restart.

A permanently blocked HAL call still cannot be killed inside this process. Worker
slots and ownership stay occupied; restarting FineTune may be needed. This design
bounds blocked workers and prevents premature release; it does not promise
recovery from every kernel/daemon failure without restarting the process.

## Engine

Pending creation is represented by a placeholder tap plus a token. Stop, ignore
and route replacement cancel that lifetime. Late results cannot publish into a
new route or resurrect a stopped tap. Pending placeholders receive parameter/DSP
updates. Recovery and manual rebuild require successful retirement acknowledgement
before replacement; cancelling a caller propagates into native work ownership.

## Scope and follow-up in High

The migration covers process-tap capture lifecycle, render state, retirement and
shutdown listener removal. Other monitor enumeration, volume queries/setters and
listener registration still contain synchronous HAL calls. This is not a claim
that every HAL call in the entire app is off MainActor.

The controlled adapter tests hold prepare/start/destroy, inspect MainActor progress,
check late completion cleanup, quarantined resource lifetime and each creation
failure. They also exercise pending engine creation, route changes, stop, burst
admission, retirement rejection and context identity across promotion. The native
isolated host supports --sanitizer thread/address for these integration checks.

Next: execute the remote CI, run physical playback/device/sleep-wake matrices,
check sustained load/latency and prepare a signed candidate only after that QA.
If those tests expose a new concurrency defect, diagnose/fix that defect in
Extra High. General monitor HAL migration is a distinct remaining area if the
product requires the entire UI to tolerate a wedged daemon on every operation.
