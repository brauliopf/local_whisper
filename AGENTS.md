# Repository instructions

These instructions govern changes to the repository. Project behavior belongs in `README.md`; change and validation rules belong here.

## Editing

- Preserve unrelated working-tree changes.
- Keep app code under `local_whisper/` and app tests under `local_whisperTests/`.
- Keep backend source and tests under `backend/src/`. Treat `backend/dist/` as generated output.
- Add tests with every meaningful behavior change. Prefer deterministic tests with injected dependencies and actionable failure messages.
- Keep the macOS client/backend contract compatible: routes, authentication, multipart field names, response keys, and cancellation behavior.
- Do not hard-code credentials. Do not commit `.env` files, tokens, or provider keys.
- Do not stage, commit, push, or modify external systems unless explicitly requested.

## Validation

[`clean-state-checklist.md`](clean-state-checklist.md) is the definition of done for application changes.

The implementation model must:

1. Request approval before validation.
2. Delegate validation to an independent model through the subagent tool.
3. Provide the validator the current repository state and checklist.
4. Apply fixes from validator feedback.
5. Request a fresh independent validation after each fix.

The implementation model is not the validation authority. A validator returns `PASS` only when every applicable check passes with evidence. It returns `FAIL` when a check fails, cannot run, or lacks sufficient evidence.

Every validator report must include:

- Commands run and results
- Passed and failed checks
- Detailed, actionable feedback for each failure
- Environment blockers and residual risks
- Manual checks not performed

Run the automated gate with:

```sh
bash scripts/clean_state_check.sh
```

A successful build alone is not completion. The relevant build, architecture, runtime, and manual checks in `clean-state-checklist.md` must also pass. Exceptions require explicit approval and must be recorded in the final report.

## Pull requests

- Use `<type>: <short imperative description>` as the title.
- Allowed types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `style`, `perf`, `ci`, `build`, `revert`.
- Use `.github/pull_request_template.md`.
- Report the summary, tests, skipped checks, breaking changes, configuration changes, and security considerations.
- Never include credentials, tokens, or `.env` files.
