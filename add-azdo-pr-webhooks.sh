#!/bin/bash
#
# Azure DevOps Pull Request Webhook Setup Script
# Creates service hook subscriptions for Pull Request event types
#
# Usage: ./add-azdo-pr-webhooks.sh
#
# The script will prompt you for:
#   - Azure DevOps Organization URL (e.g., https://dev.azure.com/myorg)
#   - Azure DevOps Project Name
#   - Webhook URL to receive notifications
#   - HTTP Header to include (format: "Header-Name: Header-Value")
#
# Prerequisites:
#   - Azure CLI installed with DevOps extension
#   - Logged in to Azure DevOps (az login)
#
# Example:
#   ./add-azdo-pr-webhooks.sh
#   (then follow the prompts)
#

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Azure DevOps resource ID for authentication
AZDO_RESOURCE="499b84ac-1321-427f-aa17-267ca6975798"

# Function to print colored messages
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Prompt for all required values
echo ""
read -p "Enter Azure DevOps Organization (e.g., myorg OR https://dev.azure.com/myorg): " AZDO_ORG
read -p "Enter Azure DevOps Project Name: " AZDO_PROJECT
read -p "Enter Webhook URL (e.g., https://myapp.com/webhook): " WEBHOOK_URL
read -p "Enter HTTP Header (e.g., X-Auth-Token: secret123): " HTTP_HEADER
echo ""

# Normalize organization URL - accept either just org name or full URL
if [[ ! "$AZDO_ORG" =~ ^https?:// ]]; then
    # User entered just the org name, prepend the base URL
    AZDO_ORG="https://dev.azure.com/${AZDO_ORG}"
fi

# Ensure org URL doesn't have trailing slash
AZDO_ORG="${AZDO_ORG%/}"

print_info "Organization: $AZDO_ORG"
print_info "Project: $AZDO_PROJECT"
print_info "Webhook URL: $WEBHOOK_URL"
print_info "HTTP Header: $HTTP_HEADER"

# Get project ID using REST API directly (more reliable)
print_info "Fetching project ID..."

# Create a temp file for error output
ERROR_FILE=$(mktemp)
trap "rm -f $ERROR_FILE" EXIT

# Capture stdout separately from stderr - use --resource for Azure DevOps authentication
if ! PROJECT_RESPONSE=$(az rest \
    --method get \
    --uri "${AZDO_ORG}/_apis/projects/${AZDO_PROJECT}?api-version=7.1" \
    --resource "$AZDO_RESOURCE" \
    2>"$ERROR_FILE"); then
    print_error "Failed to fetch project. Error:"
    cat "$ERROR_FILE"
    print_error "Make sure you're logged in (az login) and have access to the project."
    exit 1
fi

# Check if response is valid JSON
if ! echo "$PROJECT_RESPONSE" | jq empty 2>/dev/null; then
    print_error "Invalid JSON response from API:"
    echo "$PROJECT_RESPONSE"
    if [ -s "$ERROR_FILE" ]; then
        print_error "Error output:"
        cat "$ERROR_FILE"
    fi
    exit 1
fi

PROJECT_ID=$(echo "$PROJECT_RESPONSE" | jq -r '.id // empty')

if [ -z "$PROJECT_ID" ]; then
    print_error "Failed to get project ID from response:"
    echo "$PROJECT_RESPONSE" | jq . 2>/dev/null || echo "$PROJECT_RESPONSE"
    exit 1
fi

print_info "Project ID: $PROJECT_ID"

# Valid Pull Request event types in Azure DevOps
# Note: "git.pullrequest.commented" does NOT exist - comments trigger "ms.vss-code.git-pullrequest-comment-event"
# but that requires a different publisher. The standard PR events are:
PR_EVENTS=(
    "git.pullrequest.created:Pull request created"
    "git.pullrequest.updated:Pull request updated"
    "git.pullrequest.merged:Pull request merged"
    "ms.vss-code.git-pullrequest-comment-event:Pull request commented on"
)

# Function to create a service hook subscription via REST API
create_webhook_subscription() {
    local event_type="$1"
    local event_description="$2"
    
    print_info "Creating webhook for event: $event_description ($event_type)..."
    
    # Build the JSON payload
    # Using [Any] for repository, branch, etc. by not specifying them (defaults to all)
    local payload=$(cat <<EOF
{
    "publisherId": "tfs",
    "eventType": "$event_type",
    "resourceVersion": "1.0",
    "consumerId": "webHooks",
    "consumerActionId": "httpRequest",
    "publisherInputs": {
        "projectId": "$PROJECT_ID"
    },
    "consumerInputs": {
        "url": "$WEBHOOK_URL",
        "httpHeaders": "$HTTP_HEADER",
        "resourceDetailsToSend": "all",
        "messagesToSend": "all",
        "detailedMessagesToSend": "all"
    }
}
EOF
)

    # Make the REST API call using az rest - capture stderr separately
    local response
    local error_output
    error_output=$(mktemp)
    
    if ! response=$(az rest \
        --method post \
        --uri "${AZDO_ORG}/_apis/hooks/subscriptions?api-version=7.1" \
        --body "$payload" \
        --headers "Content-Type=application/json" \
        --resource "$AZDO_RESOURCE" \
        2>"$error_output"); then
        print_error "Failed to create webhook for $event_type"
        print_error "Error: $(cat "$error_output")"
        rm -f "$error_output"
        return 1
    fi
    rm -f "$error_output"
    
    # Check if response is valid JSON before parsing
    if ! echo "$response" | jq empty 2>/dev/null; then
        print_warn "Response is not valid JSON:"
        echo "$response"
        return 1
    fi
    
    # Extract subscription ID from response
    local sub_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)
    
    if [ -n "$sub_id" ]; then
        print_info "✓ Successfully created webhook subscription: $sub_id"
    else
        print_warn "Webhook may have been created but could not extract subscription ID"
        echo "$response" | jq . 2>/dev/null || echo "$response"
    fi
}

# Main execution
echo ""
print_info "Creating webhooks for ${#PR_EVENTS[@]} Pull Request events..."
echo ""

success_count=0
fail_count=0

for event_entry in "${PR_EVENTS[@]}"; do
    event_type="${event_entry%%:*}"
    event_desc="${event_entry##*:}"
    
    if create_webhook_subscription "$event_type" "$event_desc"; then
        ((success_count++))
    else
        ((fail_count++))
    fi
    echo ""
done

# Summary
echo "=========================================="
print_info "Webhook creation complete!"
print_info "Successful: $success_count"
if [ $fail_count -gt 0 ]; then
    print_warn "Failed: $fail_count"
fi
echo "=========================================="

# List created subscriptions
print_info "Listing PR-related service hook subscriptions..."
SUBS_ERROR=$(mktemp)
if SUBS_RESPONSE=$(az rest \
    --method get \
    --uri "${AZDO_ORG}/_apis/hooks/subscriptions?api-version=7.1" \
    --resource "$AZDO_RESOURCE" \
    2>"$SUBS_ERROR"); then
    echo "$SUBS_RESPONSE" | jq -r '.value[] | select(.eventType | startswith("git.pullrequest")) | "  - \(.eventType): \(.id)"' 2>/dev/null || print_warn "Could not parse subscriptions response"
else
    print_warn "Could not list subscriptions: $(cat "$SUBS_ERROR")"
fi
rm -f "$SUBS_ERROR"

exit $fail_count
