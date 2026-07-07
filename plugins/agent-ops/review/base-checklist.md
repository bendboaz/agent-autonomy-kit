Review the diff for:
  (a) adequate test coverage for the changed logic;
  (b) dead or deprecated code that should be removed;
  (c) correctness and maintainability consistent with the surrounding code;
  (d) the role-header convention: any comment posted programmatically by an agent must begin with its
      role header (`[Implementing Agent]` / `[Reviewing Agent]`); a human comment is unprefixed.
  (e) docs-without-code: if the diff only touches documentation but the linked issue calls for a code
      change, flag it High — a correct-looking docs diff with no implementation is a missing feature,
      not a clean PR.

Be concise and specific (file + line where useful). Group findings by severity (High / Medium / Low).
If everything looks good, say so briefly rather than inventing issues.
