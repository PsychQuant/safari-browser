# references/

Local copies of external projects kept for grep-ability, offline access, and pinning against upstream drift. **Not a curation layer** — each entry is a raw clone / copy of its source, not a project-specific notes file.

## Current entries

| Path | Source | Why bundled |
|---|---|---|
| `agent-browser/` | [browser-use/agent-browser](https://github.com/browser-use/agent-browser) | Sibling project in the AI-browser-automation space; detailed comparison at `/Users/che/Developer/agent-browser` where both coexist. Bundled for local diff of CLI primitives vs safari-browser's snapshot/ref-based surface. |
| `mas/` | [mas-cli/mas](https://github.com/mas-cli/mas) | Swift CLI reference (ArgumentParser + binary distribution patterns) consulted during initial safari-browser CLI scaffolding. |

## Intentional omissions

### `browser-harness/` — cited by URL, not bundled

`browser-use/browser-harness` is referenced in several specs / proposals:

- `openspec/specs/playbook-skills/spec.md` — the `domain-skills/<site>/*.md` inspiration for the playbook convention
- `openspec/changes/persistent-daemon/design.md` — `daemon.py` architecture + `BU_NAME` namespace
- `openspec/changes/persistent-daemon/proposal.md` — JSON-lines IPC protocol format + `~370ms → ~60–100ms` latency model

Follow-up **#36** evaluated whether to mirror this repo into `references/browser-harness/` per the `#32` Phase 1 scope and concluded **no, cite by URL**:

1. The precedent (`agent-browser/`) is a 21-MB raw clone with no curation value beyond `git clone`. Replicating the pattern for browser-harness would add ~10–20 MB of files that drift against upstream.
2. The `#32` Phase 1 framing assumed Wave 2 proposals needed a "common local reference" to cite — empirically false. Three proposals (`playbook-skills`, `persistent-daemon`, plus the `#37` security-gap delta in progress) cite browser-harness by URL without local access. No blocker emerged.
3. Raw clones under `references/` pollute PR diffs when updated and become a maintenance question (when to refresh? what happens if upstream deletes the repo?). A URL citation has none of those costs.

This decision is reversible — if a future workflow needs offline browser-harness access (e.g. air-gapped review, pinned version for a specific proposal), run `git clone https://github.com/browser-use/browser-harness.git references/browser-harness` and update the table above. But the default is: **cite by URL unless a concrete local-access need exists**.

See [#36](https://github.com/PsychQuant/safari-browser/issues/36) closing comment for full rationale.

## Adding a new reference

Before cloning a repo under `references/`, ask:

1. Can the material be cited by URL instead? (Usually yes. Prefer URL.)
2. Is offline access or upstream-pin required for a concrete use case? (If yes, bundle.)
3. Will the clone be maintained? If no, bundling adds debt.

If bundling:

```bash
git clone --depth 1 https://github.com/<owner>/<repo>.git references/<repo-name>
# Update the "Current entries" table above with source URL + why-bundled rationale.
```

No submodules — plain clones keep the tree self-contained and avoid submodule-init friction for new contributors. Refresh via `git -C references/<name> pull` when needed and note the refresh date in the table rationale.
