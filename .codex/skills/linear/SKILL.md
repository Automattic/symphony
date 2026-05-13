---
name: linear
description: |
  Use Symphony's scoped Linear dynamic tools for current-issue reads and narrow
  current-issue writes.
---

# Linear Tools

Use the scoped `linear.*` tools exposed by Symphony's app-server session. These
tools inject the current issue id server-side and do not accept issue id
arguments from prompts.

## Read Tools

- `linear.get_current_issue` with `{}`: full fields for the current issue.
- `linear.get_subissues` with `{}`: direct children of the current issue.
- `linear.get_parent_issue` with `{}`: parent issue, or `null`.
- `linear.get_comments` with optional `{"limit": 50}`: current issue comments,
  newest first.
- `linear.get_related_issues` with `{}`: blocks and blocked-by issue summaries
  only: id, identifier, and title.

## Write Tools

- `linear.update_state` with `{"state_name_or_id": "In Review"}`: resolves the
  state against the current issue team's workflow. Unknown states are a no-op.
- `linear.set_assignee` with `{"assignee": "self"}`, `{"assignee": "unassign"}`,
  or `{"assignee": "<user_id>"}`.
- `linear.add_comment` with `{"body": "..."}`: adds a comment to the current
  issue and records ownership for this run.
- `linear.update_comment` with `{"comment_id": "...", "body": "..."}`: only for
  comments created earlier by this run.
- `linear.delete_comment` with `{"comment_id": "..."}`: only for comments
  created earlier by this run.
- `linear.attach_url` with `{"url": "https://...", "title": "..."}`: attaches a
  valid HTTP(S) URL to the current issue. Titles are capped.
- `linear.attach_file` with `{"local_path": "path/in/workspace", "title": "..."}`:
  uploads and attaches a file only when the path resolves inside the workspace.

## Rules

- Do not use or request `linear_graphql`; it is intentionally unavailable to
  prompts.
- Do not include `issue_id`, `issueId`, or `id` arguments. The server rejects
  prompt-supplied issue ids.
- Do not create issues, delete issues, update issue titles/descriptions, move
  issues between teams/projects/parents/cycles, or write labels.
- If a task truly requires a Linear operation outside this surface, stop and
  record the missing capability as a follow-up instead of trying to bypass the
  tool boundary.
