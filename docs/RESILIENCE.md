# Automation Recovery (1.7)

Recording and automation are separate concerns. Saving frames does not prove
that a replay has entered, playback is running or the requested side is visible.
The HUD reports those confirmations separately.

## States and Transitions

| Condition | State / action | Resume requirement |
| --- | --- | --- |
| Fresh, stable target page | Observe, then bounded input | Current page evidence and hit test |
| Input obscured or target temporarily unfocused | Defer input; independent-window capture continues | Two stable readiness samples, then new screenshot / recognition |
| Replay entry unconfirmed after retry budget | Keep saving; show assistance | Two fresh replay-control observations; no unlimited Play clicks |
| Playback paused or board unchanged | Warn, attempt bounded recognized Continue, mark metadata for review | Fresh playback evidence or explicit human assistance |
| Unknown startup/dialogue state | Wait for assistance without discarding the task | Explicit Continue, new recognition, new bounded attempt |
| Outdoor/map screen without verified route | Wait; never infer a tavern teleport | Strong NPC entrance or replay-list evidence |
| Final result stable | Finalize/export, then observe return to favorites | Stable list or one recognized exit; no repeated blind exit |
| Stop, lock, revoked permissions, closed/minimized target, real capture failure, take limit | Save partial and stop input | New explicit operation after correcting the condition |

Before an unsent click is retried, its coordinator state is rolled back and its
old screenshot discarded. Sent key-down events are tracked separately and their
key-up is always paired. Geometry changes before recording cause a new page
check; recording-time geometry changes remain a safe stop. Unknown alerts are
never dismissed automatically.

Human waiting does not consume a startup navigation deadline. It does consume
the active take limit, which bounds disk use even during recovery. Finishing an
already-ended take clears this limit before export. Password submission remains
one attempt per startup operation, including after explicit assistance.

## Recording Choices

Scheduling (`own`, `opponent`, `both`) is separate from physical orientation
(`own`, `opponent`). Only selected rows generate jobs. A mixed plan containing a
both-view row records required own jobs first, then required opponent jobs.
The global both-view override temporarily supersedes row choices without
mutating them. Old single-side JSON remains readable. A mismatching rescan
cannot silently replace deliberate choices or manually confirmed characters.

## System Focus Ownership

Focus is read and changed through public accessibility controls in Control
Center, not private preference databases. The control layout is validated before
any mode toggle. Expanded duration options reuse their parent identifier; the
main row must be taller, above and aligned with the smaller duration rows.
Ambiguous layouts are rejected rather than guessed.

Panel navigation requires two consecutive expanded-header observations. A
disappearing panel is allowed to finish animating before a single bounded menu
reopen; stale AX nodes cannot leave the loop waiting on a panel already closed.
This navigation state never authorizes a mode toggle by itself.

The original mode is journaled before enabling Do Not Disturb, including when
another Focus is already active. A second read must confirm DND before a take
or its Play click begins. Failure waits for explicit assistance/recheck instead
of silently recording without the requested protection. Crash-journal recovery
also requires explicit continuation. Already-active DND is not owned or disabled.
Finalization uses uncancelled cleanup; only the mode still owned by this
operation is restored. User changes are preserved. Failed restoration leaves
an explicit recovery action. Corrupt journals block further automatic toggles,
and are cleared only after manual restoration has been observed. The app does
not reconstruct system countdowns or schedules. Notification exceptions and
cross-device Focus sharing still apply; critical/security alerts are not
guaranteed suppressed.

Independent-window capture excludes other windows. Display-region capture
explicitly excludes the recorder, Notification Center and Control Center.
Only the two exact system overlay bundle IDs may bypass region focus loss;
unrelated apps, unknown IDs, locks and missing targets retain their safety stop.
Exclusion does not authorize input through an overlay or enlarge the selected
capture region, and does not filter system notification sounds.

## Evidence Boundaries

See [ACCEPTANCE.md](ACCEPTANCE.md) for commands. Seeded observation tests,
fake-backend lifecycle checks, offline screenshots and a live generated-window
capture exercise different boundaries. None proves real cloud-game navigation,
keep-alive, perspective changes or a complete unattended batch. Release notes
must distinguish those outcomes; historical indoor screenshots cannot stand in
for an outdoor navigation recording.
