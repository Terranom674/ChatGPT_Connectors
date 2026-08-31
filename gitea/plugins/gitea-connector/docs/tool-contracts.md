# Read-only MCP tool contracts

All list tools accept optional `page` and `limit`. The server caps `limit` at 50 and returns pagination metadata.

## `list_repositories`

Lists repositories visible to the authenticated user.

- Inputs: optional `page`, `limit`.
- Output: repository ID, owner, name, full name, visibility/private flag, default branch, updated timestamp, web URL.
- Authorization: authenticated Gitea user with read access.
- Side effects: none.

## `get_repository`

Gets one repository by explicit owner and name.

- Inputs: `owner`, `repo`.
- Output: the repository fields above plus description, archived flag, empty flag, and feature availability.
- Authorization: repository read access.
- Side effects: none.

## `list_branches`

Lists branches for one repository.

- Inputs: `owner`, `repo`, optional pagination.
- Output: branch name, commit ID, protected flag, effective access flags when available.
- Authorization: repository code read access.
- Side effects: none.

## `list_commits`

Lists commits for one repository and optional branch or SHA.

- Inputs: `owner`, `repo`, optional `sha`, `path`, `page`, `limit`.
- Output: commit SHA, message, author/committer summary, timestamp, web URL.
- Authorization: repository code read access.
- Side effects: none.

## `list_issues`

Lists issues without silently mixing pull requests into the result.

- Inputs: `owner`, `repo`, optional `state`, `labels`, pagination.
- Output: issue number, title, state, author, labels, assignees, timestamps, web URL.
- Authorization: issue read access.
- Side effects: none.

## `get_issue`

Gets one issue by repository and number.

- Inputs: `owner`, `repo`, `index`.
- Output: issue fields plus body and milestone summary.
- Authorization: issue read access.
- Side effects: none.

## `list_pull_requests`

Lists pull requests for one repository.

- Inputs: `owner`, `repo`, optional `state`, `sort`, pagination.
- Output: pull request number, title, state, draft flag, author, head/base refs and SHAs, mergeable status when available, timestamps, web URL.
- Authorization: pull-request read access.
- Side effects: none.

## `get_pull_request`

Gets one pull request by repository and number.

- Inputs: `owner`, `repo`, `index`.
- Output: pull-request fields plus body, labels, assignees, requested reviewers, and merge metadata.
- Authorization: pull-request read access.
- Side effects: none.

## `create_issue`

Creates one confirmed issue.

- Inputs: `owner`, `repo`, `title`, optional `body`, `assignees`, and numeric `label_ids`.
- Output: compact created issue including number and URL.
- Side effects: creates an issue; never retried automatically.

## `comment_on_issue`

Adds one confirmed comment to an issue or pull request.

- Inputs: `owner`, `repo`, `index`, `body`.
- Output: compact created comment including ID and URL.
- Side effects: publishes a comment; never retried automatically.

## `create_pull_request`

Creates one confirmed pull request between two existing, different branches.

- Inputs: `owner`, `repo`, `head`, `base`, `title`, optional `body`, `assignees`, `reviewers`, and numeric `label_ids`.
- Output: compact created pull request including number and URL.
- Side effects: creates a pull request; never retried automatically.
