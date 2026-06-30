# AI review checklist — &lt;owner/repo&gt;

Project-specific checks the AI reviewer applies, appended to the kit's base checklist. Keep this in the
consuming repo at `.agent-ops/REVIEW-CHECKLIST.md`. Replace the placeholders with your repo's specifics:

- **Conventions enforced by review:** e.g. styling rules; no `any` to silence the compiler; import style.
- **Contract / frozen files** — flag any change to their exported types/signatures as a contract break:
  list the files here. Note carve-outs (e.g. `*.test` files are exempt).
- **Recurring issues** reviewers repeatedly catch in this repo: list them so the reviewer pre-empts them.
