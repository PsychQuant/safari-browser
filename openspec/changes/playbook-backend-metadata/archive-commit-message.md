# Draft archive commit message

此檔僅作為 `spectra archive` 時的 commit message 參考稿,不會被歸檔流程自動使用。Archivist 在執行 `spectra archive playbook-backend-metadata` 前,應把第一段 + 第二段內容貼入 commit message 的 body 部分。

---

## Commit subject

```
feat(spec/playbook-skills): add backend frontmatter for multi-backend playbook routing
```

## Commit body

```
Modify the playbook-skills capability's `Playbook skill frontmatter`
requirement to accept optional `backend` (single value or preference
array drawn from {safari, chrome, playwright, any}) and
`backend_reason` (human-readable rationale). Relax the "exactly three
keys" rule, condition the description disambiguation requirement on
the declared backend, and define `backend: safari` as the backward-
compatibility default when the field is omitted. Existing seed
playbooks (safari-plaud-upload, safari-github-star) remain valid
without modification.

Follow-up work — out of scope for this change, tracked as separate PRs:
  1. psychquant-claude-plugins repo: update
     plugins/safari-browser/skills/CONTRIBUTING-PLAYBOOKS.md to
     document the new `backend` / `backend_reason` keys.
  2. psychquant-claude-plugins repo: retro-apply explicit
     `backend: safari` + `backend_reason` to safari-plaud-upload and
     safari-github-star (cosmetic, not required for validity).
  3. tool-finder plugin: add a `which-browser` sub-skill encoding the
     safari / chrome / playwright decision tree (decision advisor C
     route from the upstream design discussion).
```
