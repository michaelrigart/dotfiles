---
name: merge-request
description: Use before opening any merge request or pull request, with gh, glab or az, and when writing its title or body. Covers finding and filling the repository's template, rendering the text, and the no-attribution rule.
---

# Merge requests

- **Follow the repository's template.** Look in `.gitlab/merge_request_templates/*.md`,
  `.github/pull_request_template.md` or `.github/PULL_REQUEST_TEMPLATE*`,
  `.azuredevops/pull_request_template.md` or `pull_request_template/`, the repository root,
  and `docs/`.
- **Fill it faithfully:** keep its headings, order and checklists; fill every section (`n/a`
  with a one-line reason, never deleted); tick a box only when done; strip comments to the
  author. Several templates: pick one and say which. None: what / why / how to verify.
- **Render the text yourself,** because the CLIs don't expand templates:
  `gh pr create --body-file <f>`, `glab mr create --description "$(cat <f>)"`,
  `az repos pr create --description "$(cat <f>)"`.
- **Never add agent attribution.** That means no session links, no `Claude-Session:`
  trailers, no `Co-authored-by:` agent lines, no "Generated with…" footers, and no naming
  of the tool. This holds in commits, MR/PR titles and bodies, issues and review comments.
  The published record is Michael's.
