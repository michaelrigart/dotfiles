---
name: merge-request
description: Use before opening any merge request, pull request or issue, with gh, glab or az, and when writing its title or body. Covers finding and filling the repository's template, rendering the text, assigning Michael, and the no-attribution rule.
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
- **Assign Michael** to every PR, MR and issue you open, at creation, because agents act as
  him and the self-assignee is him: `gh pr create --assignee @me`,
  `gh issue create --assignee @me`. glab has no `@me`: take the login from
  `glab api user | jq -r .username`, run in the target repo's checkout or with
  `--hostname <the MR's host>`, and pass `glab mr create --assignee <login>` or
  `glab issue create --assignee <login>`. If the lookup prints nothing or `null`, omit the flag.
  Azure DevOps PRs have no assignee, so `az repos pr create` gets none. An Azure Boards work item
  does: `az boards work-item create --assigned-to "$(az account show --query user.name -o tsv)"`.
  Where Michael cannot be assigned (no triage access, e.g. an upstream repo), drop the flag, say
  so in your report, and do not retry the create.
- **Never add agent attribution.** That means no session links, no `Claude-Session:`
  trailers, no `Co-authored-by:` agent lines, no "Generated with…" footers, and no naming
  of the tool. This holds in commits, MR/PR titles and bodies, issues and review comments.
  The published record is Michael's.
