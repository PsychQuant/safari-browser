# Native upload readiness evidence (#171)

This report separates the generated AppleScript decision/confirmation fragment
from a complete Safari upload. The production flow now observes immediately
and waits only for a readable empty selection (`PENDING`) or the existing
pending delivery receipt after its chooser disappears. Unknown or conflicting
native evidence still refuses confirmation. The original monotonic deadline,
clipboard and target guards, and the second selected-path read remain.

## Controlled fragment comparison

`NativeUploadReadinessTests` extracts the actual generated fragment. It replaces
external UI observations and AX actions with owned fixture responses/counters,
and replaces the clock with a controlled value. Its delay adapter executes the
requested AppleScript delay before advancing that controlled clock. Therefore
wall time includes an osascript process and a controlled fragment, not native
AX traversal, Safari latency, clipboard traffic or actual file delivery.

The old fragment is byte-identical to the post-Paste source at `0e2e395`;
the concurrent #179 work did not change this phase. Five samples per immediate
scenario were collected before the change, then five after it, in fixed order.
These small cohorts are not a statistical speedup guarantee. Raw rows and
source hashes are in [the recorded data](benchmarks/native-readiness-2026-09-29.json).

| Fixture | Before | After |
|---|---|---|
| Immediate selected path | 5/5 phase completions; 100 ms requested wait each; 214.4 ms median wall time | 5/5; no requested wait; 50.6 ms median |
| Delivery already observed | 5/5; 100 ms requested wait each; 161.0 ms median | 5/5; no requested wait; 50.5 ms median |
| Pending, then matching selection | 0/1 phase completions | 1/1 after one 100 ms wait |
| Selected-path reads for immediate MATCH | 2 per call | 2 per call |

A phase completion or confirmation counter is not proof of an uploaded file.
The fragment leaves actual delivery and chooser closure to the existing final
completion phase. Unknown evidence and a changed second selected-path read
produce zero confirmation counters. Persistent pending requests 100 ms then
50 ms against an injected 150 ms deadline and fails without confirmation.
Injected cancellation, focus, target and clipboard guard failures stop the
fragment; this does not replace real worker/process or GUI cancellation tests.

## Validation boundaries

The first adapter attempt used AppleScript's `seconds` keyword as a parameter
and failed before exercising production behavior; it is excluded from RED and
from these measurements. Correcting the adapter produced behavioral REDs on
the original fixed-delay fragment. The new flow passes the same fixture cases.

The pending classifier accepts empty selected collections only after successful
bounded reads in a supported view and final ownership checks. A missing leaf
inside a selected group, unreadable attributes, an unsupported view, wrong file,
ambiguity and traversal limits remain unavailable. Removing that distinction,
retrying unknown evidence, removing the remaining-time clip, or dropping the
last selected-path check each fails a behavioral mutation test.

Real Safari column/list/icon views, special paths, large files, delayed selection,
actual cancellation, clipboard restoration and end-to-end latency/success rate
remain part of the shared #101/#169/#179 native acceptance. No GUI acceptance
was performed for this comparison. Other waits inventoried in #171, including
PDF activation and screenshot rendering, have not been declared optimized.
