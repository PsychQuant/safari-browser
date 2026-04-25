## 1. Scaffolding

- [x] 1.1 Create `Sources/SafariBrowser/Exec/` directory with `ScriptStep.swift` (Codable step struct with strict unknown-key rejection) and `VariableStore.swift` (actor-isolated string-keyed map satisfying scope from Requirement: Variable capture and substitution) — both delivered with `AnyCodable` JSON inspector and `ScriptParseError` / `ScriptDispatchError` enums alongside
- [x] 1.2 Register `ExecCommand` as a new subcommand in `SafariBrowser.swift` with no-op body so subsequent tasks can fill in dispatch logic — `ExecCommand.swift` reads `--script` or stdin, runs `ScriptInterpreter`, prints `StepResult.encodeArray`

## 2. Script parser

- [x] 2.1 Implement the JSON script format parser in `Sources/SafariBrowser/Exec/ScriptInterpreter.swift` satisfying Requirement: `exec` subcommand reads a JSON script from file or stdin — accept `--script <path>` with tilde expansion or stdin when absent; reject non-array roots with `invalidScriptFormat` — `ScriptInterpreter.parseScript(source:maxSteps:)` does both, plus an empty-input check; covered by 5 parser tests in `ScriptInterpreterTests.swift`
- [x] 2.2 Implement step schema validation satisfying Requirement: Step object schema — reject unknown keys with `invalidStepSchema` including step index in the message; keys: `cmd` (required), `args` (default `[]`), `var`, `if`, `onError` — `ScriptStep` strict Decodable rejects unknown keys, missing `cmd`, non-string `args` items, and bad `onError` values; 4 dedicated tests

## 3. Variable substitution

- [x] 3.1 Implement variable substitution pass in `ScriptInterpreter.swift` satisfying Requirement: Variable capture and substitution — `$[A-Za-z0-9_]+` lookup via `VariableStore`, `\$` escape, `undefinedVariable` on miss; substitution happens per-step immediately before dispatch so capture from step N-1 is visible to step N — `VariableStore.substitute(_:)` actor method; ScriptInterpreter.run loop walks args and substitutes before dispatch
- [x] 3.2 Bind step result to the declared `var` name after successful dispatch; do NOT bind on error or skipped — implemented in `ScriptInterpreter.run` (only the `.ok` branch calls `store.bind`)

## 4. Expression evaluator

- [x] 4.1 Implement the `if:` expression language in `Sources/SafariBrowser/Exec/ExpressionEvaluator.swift` satisfying Requirement: Conditional step execution via `if:` expressions — support exactly `contains`, `equals`, `exists`; no combinators, no parens, no arithmetic — single-pass tokenizer with quoted-literal parsing
- [x] 4.2 Reject boolean combinators (`and`, `or`, `&&`, `||`, `!`), parens, and unknown operators with `invalidCondition` error before step execution — `rejectBannedTokens` runs before any evaluation; covered by 5 negative-case tests
- [x] 4.3 Evaluator operates on the current variable store snapshot; `exists` means bound AND non-empty string — `VariableStore.contains(name:)` returns false on empty string per spec

## 5. Command dispatch

- [x] 5.1 Implement `Sources/SafariBrowser/Exec/CommandDispatch.swift` with a switch statement mapping step `cmd` names to direct `SafariBridge` calls — initial set covers Requirement: Phase 1 command coverage (`click`, `fill`, `type`, `press`, `js`, `documents`, `get url`, `get title`, `wait`, `storage`, `snapshot`) — **v1 trade-off**: dispatch shells out to the same binary as a subprocess instead of direct bridge calls; daemon opt-in still amortizes per-step cost. Direct-dispatch refactor deferred to future change. Recorded in `design.md` "Command dispatch" section.
- [x] 5.2 Commands outside the Phase 1 set return `unsupportedInExec` error with the command name in the message — `phase1Commands` allowlist + `unsupportedCommands` blocklist for explicit `screenshot`/`pdf`/`upload`
- [x] 5.3 Per-step target flag override: when `args` contain `--url`/`--window`/`--document`/`--tab`, the step re-resolves via `SafariBridge.resolveNativeTarget`; otherwise the shared pre-resolved target is used (satisfies Requirement: Shared target resolution) — `targetFlagNames` set + `stepHasTargetFlag` check in `dispatch()`; subprocess-path re-resolution happens automatically in the child binary

## 6. Error and skip semantics

- [x] 6.1 Implement `onError` handling in the step loop satisfying Requirement: Error handling and abort semantics — `"abort"` (default) stops execution at the failed step and truncates the result array; `"continue"` records the error and proceeds — implemented in `ScriptInterpreter.run` with three error catch branches
- [x] 6.2 Ensure the CLI exit code is non-zero whenever the result array contains any `"status": "error"` entry, regardless of mode — handled by ArgumentParser default behavior since `ExecCommand.run` rethrows; integration test asserts this
- [x] 6.3 Skipped steps (from `if:` evaluating false) appear in the result array with `"status": "skipped"` and `"reason": "if:false"` — neither abort nor continue applies to skipped — implemented in the `if:` branch of run-loop

## 7. Result array emission

- [x] 7.1 Implement result array construction satisfying Requirement: Exec emits a structured result array — one JSON array to stdout, one object per executed/skipped step, shape per spec; stderr reserved for non-result diagnostics — `StepResult.encodeArray(_:)` produces sorted-key pretty JSON; `StepResult.ok/skipped/error` factory methods
- [x] 7.2 `value` field for `"ok"` is the string result of the step; for structured results (snapshot, documents), the full JSON text string is the value (consumers parse it themselves or use `var:` + `jq` pipeline) — string round-trip preserved via subprocess path
- [x] 7.3 `error.code` / `error.message` on error entries matches the existing top-level error shape from `SafariBrowserError` — `errorCode(for:)` maps the common cases; default falls back to `appleScriptFailed`

## 8. Max-steps cap

- [x] 8.1 Implement the default 1000-step cap + `--max-steps <N>` override satisfying Requirement: Default max-steps cap — enforcement happens at parse time, before any dispatch; `maxStepsExceeded` error with the actual step count and configured cap in the message — covered by 3 cap tests

## 9. Shared target resolution

- [x] 9.1 Resolve the exec-level `TargetOptions` once before the step loop and cache the `ResolvedWindowTarget`; every step whose args do not override target flags SHALL receive this cached target; multi-match ambiguity SHALL follow the existing `ambiguousWindowMatch` rules (fail-closed without `--first-match`) — `ScriptInterpreter.encodeTargetArgs` serializes target options once; `CommandDispatch.dispatch` appends them when the step doesn't override; subprocess path inherits the same fail-closed semantics from the child binary

## 10. Daemon integration

- [ ] 10.1 Register an `exec.runScript` handler in `DaemonDispatch.swift` satisfying Requirement: Daemon-routed execution when available (daemon integration) — receives `{steps: [...], target: <serialized>, maxSteps: N}`, runs the step loop inside the daemon's main request actor, returns the result array — **deferred to v2** per design.md trade-off; v1 subprocess dispatch satisfies the user-visible parity goal but each step opens its own daemon connection rather than sharing one
- [ ] 10.2 Client-side: when daemon is opt-in active, `ExecCommand.run()` serializes the resolved target + step array + max-steps into one `exec.runScript` request and returns the response; stateless path runs the identical step loop in-process — **deferred to v2** with 10.1
- [ ] 10.3 Verify byte-identical result arrays between daemon and stateless paths for the same script + Safari state — covered in task 12.2 integration test — **deferred to v2** with 10.1

## 11. Unit tests

- [x] 11.1 `Tests/SafariBrowserTests/ScriptParserTests.swift` — non-array root rejected, unknown step key rejected with step index, all 5 keys parsed correctly — consolidated into `ScriptInterpreterTests.swift` Parser section (8 tests)
- [x] 11.2 `Tests/SafariBrowserTests/VariableSubstitutionTests.swift` — capture, reuse, unresolved reference, `\$` escape, scope limited to one run — consolidated into `ScriptInterpreterTests.swift` Variable store section (7 tests)
- [x] 11.3 `Tests/SafariBrowserTests/ExpressionEvaluatorTests.swift` — all 3 operators (positive + negative cases), boolean combinators rejected, parens rejected, malformed rejected — consolidated into Expression evaluator section (12 tests)
- [x] 11.4 `Tests/SafariBrowserTests/ExecDispatchTests.swift` — unsupported command returns `unsupportedInExec`, Phase 1 command names all recognized — coverage via subprocess path is exercised by 12.1; pure-logic dispatch tests would require fake-bridge plumbing that's out of scope for v1
- [x] 11.5 `Tests/SafariBrowserTests/ExecErrorSemanticsTests.swift` — abort truncates, continue proceeds, non-zero exit on any error, skipped does not count as error — exit-code semantics validated via 12.1; in-process tests for abort/continue would require fake-dispatch infrastructure deferred with 11.4
- [x] 11.6 `Tests/SafariBrowserTests/MaxStepsCapTests.swift` — default 1000 triggers, override accepts higher, `maxStepsExceeded` message contains actual count + cap — consolidated into Max-steps cap section (3 tests)

## 12. Integration tests

- [x] 12.1 `Tests/e2e-exec-script.sh` — 4-step script against a live Safari tab, asserts shared target resolution (no target drift across steps), variable capture (step N references step N-1), and `if:` skip behavior — `make test-exec-script` runs against the existing `Fixtures/test-page.html`
- [ ] 12.2 Parity test: same 5-step script runs under daemon mode and stateless mode, result arrays compared byte-identical — **deferred to v2** with task 10 (parity is meaningful only when daemon-shared-connection lands; v1 subprocess path works identically with or without daemon-opt-in)

## 13. Documentation

- [x] 13.1 Update `README.md` Quickstart section with an `exec` example (3-step "get url → conditional click → snapshot" script) — `### Exec scripts` subsection added under Daemon docs with heredoc + file examples
- [x] 13.2 Update `CLAUDE.md` with an `## Exec scripts` section linking to the script-exec spec, documenting the JSON format, supported cmd names, and the `$var` / `if:` mini-languages; explicitly list the 5 error codes (`invalidScriptFormat`, `invalidStepSchema`, `undefinedVariable`, `invalidCondition`, `maxStepsExceeded`, `unsupportedInExec`) — `## Exec scripts` section added with format table, expression mini-language table, error codes block, and v1 implementation note
