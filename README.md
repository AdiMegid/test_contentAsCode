# Content deployment state

This orphan branch is managed by generated Content as Code GitHub Actions workflows.
Do not edit state files manually.

## File layout

```text
.deployment-state/{sourceControlId}/{sanitizedBranch}.json
```

- `sourceControlId` is the unique source-control deployment connection ID supplied by the service.
  It prevents separate deployment configurations using the same repository branch from colliding.
- `sanitizedBranch` is the tracked branch name with path-unsafe characters replaced by `-`
  (for example, `scenario/one` becomes `scenario-one.json`). The JSON also stores the full
  `trackedBranch` and `sourceControlId`. If two names map to the same filename, the workflow
  rejects the mismatched identity rather than overwriting another branch's state.

Each JSON file stores the last observed source commit, the latest attempted and successful workflow
run IDs, and templates that still require deployment.
The Prepare step saves all selected candidates before Azure login. The Complete step replaces that
list with only failed templates. Deleted repository templates are removed from state, but their
Azure resources are not deleted.

State writes retry GitHub conflicts caused by deployments updating different files concurrently.
Disconnect attempts to remove only the tracking file for that connection and full tracked branch.
The shared state branch, README, and other connections' files remain.
An active workflow can recreate its state after disconnect; the service reports incomplete or
unconfirmed cleanup as a warning and does not cancel workflow runs.
Renamed or deleted source branches are not automatically offboarded.