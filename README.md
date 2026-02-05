# Azure DevOps PR Webhook Setup

Interactive script to create Azure DevOps service hook subscriptions for Pull Request events.

## Features

- Interactive prompts for all configuration values
- Accepts either organization name or full URL
- Creates webhooks for all PR event types:
  - Pull request created
  - Pull request updated
  - Pull request merged
  - Pull request commented on
- Custom HTTP headers support
- Comprehensive error handling

## Prerequisites

- Azure CLI installed with DevOps extension
- Logged in to Azure DevOps: `az login`
- Access to the target Azure DevOps organization and project

## Installation

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/azdo-webhook-setup.git
cd azdo-webhook-setup

# Make script executable
chmod +x add-azdo-pr-webhooks.sh
```

## Usage

Simply run the script and follow the prompts:

```bash
./add-azdo-pr-webhooks.sh
```

You'll be prompted for:

1. **Azure DevOps Organization** (e.g., `myorg` or `https://dev.azure.com/myorg`)
2. **Project Name** (e.g., `myproject`)
3. **Webhook URL** (e.g., `https://myapp.com/webhook`)
4. **HTTP Header** (e.g., `X-Auth-Token: secret123`)

## Example

```bash
$ ./add-azdo-pr-webhooks.sh

Enter Azure DevOps Organization (e.g., myorg OR https://dev.azure.com/myorg): myorg
Enter Azure DevOps Project Name: my-project
Enter Webhook URL (e.g., https://myapp.com/webhook): https://example.com/webhook
Enter HTTP Header (e.g., X-Auth-Token: secret123): X-Webhook-Secret: abc123

[INFO] Organization: https://dev.azure.com/myorg
[INFO] Project: my-project
[INFO] Webhook URL: https://example.com/webhook
[INFO] HTTP Header: X-Webhook-Secret: abc123
[INFO] Fetching project ID...
[INFO] Project ID: 12345678-1234-1234-1234-123456789abc
[INFO] Creating webhooks for 4 Pull Request events...

[INFO] Creating webhook for event: Pull request created (git.pullrequest.created)...
[INFO] ✓ Successfully created webhook subscription: abcd1234-5678-90ab-cdef-1234567890ab
...
```

## Troubleshooting

### Authentication Issues

Make sure you're logged in:
```bash
az login
```

### Permission Denied

Make the script executable:
```bash
chmod +x add-azdo-pr-webhooks.sh
```

### Invalid Organization

Ensure you have access to the organization and project in Azure DevOps.

## License

MIT

## Contributing

Pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change.
