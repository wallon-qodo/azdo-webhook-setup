# Azure DevOps PR Webhook Setup

Interactive script to create Azure DevOps service hook subscriptions for Pull Request events — with per-repo scoping and fzf-powered multi-select.

## Features

- Interactive prompts for all configuration values
- Accepts either organization name or full URL
- **Repo-specific scoping**: select one, multiple, or all repos in a project
- **fzf multi-select** for repo selection (falls back to numbered list if fzf not installed)
- Creates webhooks for all 4 PR event types:
  - Pull request created
  - Pull request updated
  - Pull request merged
  - Pull request commented on
- `X-Webhook-Secret` header auto-constructed from token input
- Comprehensive error handling with actionable diagnostics

## Prerequisites

- Azure CLI: `az login`
- `jq` installed
- `fzf` installed _(optional — falls back to numbered list)_
- Access to the target Azure DevOps organization and project

## Installation

```bash
git clone https://github.com/wallon-qodo/azdo-webhook-setup.git
cd azdo-webhook-setup
chmod +x add-azdo-pr-webhooks.sh
```

## Usage

```bash
./add-azdo-pr-webhooks.sh
```

You'll be prompted for:

1. **Azure DevOps Organization** — `myorg` or `https://dev.azure.com/myorg`
2. **Project Name** — exact name, case-sensitive
3. **Webhook URL** — e.g. your Qodo Merge endpoint
4. **Webhook Secret Token** — the script builds `X-Webhook-Secret: <token>` automatically
5. **Repository scope** — pick specific repos or all repos

## Example

```
$ ./add-azdo-pr-webhooks.sh

Enter Azure DevOps Organization (e.g., myorg OR https://dev.azure.com/myorg): myorg
Enter Azure DevOps Project Name: my-project
Enter Webhook URL (e.g., https://myapp.com/webhook): https://app.qodo.ai/api/v1/webhook
Enter Webhook Secret Token: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

[INFO] Organization: https://dev.azure.com/myorg
[INFO] Project: my-project
[INFO] Webhook URL: https://app.qodo.ai/api/v1/webhook
[INFO] HTTP Header: X-Webhook-Secret: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
[INFO] Fetching project ID...
[INFO] Project ID: 12345678-1234-1234-1234-123456789abc
[INFO] Fetching repositories in project...
[INFO] Found 3 repositories in project.
[INFO] Use TAB to select multiple repos. Press ENTER to confirm.

  # fzf picker opens:
  > ALL REPOS (project-wide)
    api-service          ← TAB to select
    frontend
    infra

[INFO] Scope: 2 repo(s) — api-service infra
[INFO] Creating 8 webhook subscriptions (4 events × 2 repos)...

[INFO] --- Repository: api-service ---
[INFO] Creating webhook for event: Pull request created (git.pullrequest.created) [repo: api-service]...
[INFO] ✓ Successfully created webhook subscription: abcd1234-...
...

==========================================
[INFO] Webhook creation complete!
[INFO] Scope: repos — api-service infra
[INFO] Successful: 8
==========================================
```

### No fzf installed (numbered list fallback)

```
[WARN] fzf not found. Using numbered list selection.

  0) ALL REPOS (project-wide)
  1) api-service
  2) frontend
  3) infra

Enter comma-separated numbers (e.g. 0 or 1,3): 1,3
```

## Repo Scoping Behavior

| Selection | Subscriptions created |
|---|---|
| `ALL REPOS (project-wide)` or `0` | 4 (one per event, no repo filter) |
| Single repo (e.g. `1`) | 4 (one per event, scoped to that repo) |
| Multiple repos (e.g. `1,3`) | 4 × N repos |

## Troubleshooting

### Authentication error / "not authorized"

Re-authenticate with a fresh token:
```bash
az logout
az login
```

If the error persists, verify your account has access to the ADO organization at `https://dev.azure.com/{yourorg}`.

### Wrong org or project

The script prints the exact URL it attempted — check that the org name and project name are correct. Project names are **case-sensitive**.

### Permission denied (script not executable)

```bash
chmod +x add-azdo-pr-webhooks.sh
```

### fzf not found

Install fzf for interactive repo selection:
```bash
brew install fzf        # macOS
apt-get install fzf     # Ubuntu/Debian
```

Or skip it — the script automatically falls back to a numbered list.

## Testing

```bash
bash test-webhooks.sh
```

Runs 44 tests covering payload validation, URL normalization, repo selection logic, and full E2E scenarios using a mocked `az` CLI.

## License

MIT
