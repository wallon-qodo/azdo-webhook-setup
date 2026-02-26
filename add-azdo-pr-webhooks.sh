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
#   - Webhook secret token (script builds the full X-Webhook-Secret header)
#   - Repository scope (select specific repos or all via fzf/numbered list)
#
# Optional:
#   - fzf (interactive multi-select picker; falls back to numbered list)
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
read -p "Enter Webhook Secret Token: " WEBHOOK_TOKEN
HTTP_HEADER="X-Webhook-Secret: ${WEBHOOK_TOKEN}"
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
print_info "HTTP Header: $HTTP_HEADER"  # X-Webhook-Secret: <token>

# Get project ID using REST API directly (more reliable)
print_info "Fetching project ID..."

# Create a temp file for error output
ERROR_FILE=$(mktemp)
trap "rm -f $ERROR_FILE" EXIT

# Capture stdout separately from stderr - use --resource for Azure DevOps authentication
PROJECT_API_URI="${AZDO_ORG}/_apis/projects/${AZDO_PROJECT}?api-version=7.1"
print_info "Calling: $PROJECT_API_URI"

if ! PROJECT_RESPONSE=$(az rest \
    --method get \
    --uri "$PROJECT_API_URI" \
    --resource "$AZDO_RESOURCE" \
    2>"$ERROR_FILE"); then
    print_error "Failed to fetch project."
    print_error "URL attempted: $PROJECT_API_URI"
    if [ -s "$ERROR_FILE" ]; then
        print_error "Azure CLI error:"
        cat "$ERROR_FILE"
    fi
    print_error "Common causes:"
    print_error "  1. Wrong org name — check: https://dev.azure.com/{yourorg}"
    print_error "  2. Wrong project name — names are case-sensitive"
    print_error "  3. Not logged in — run: az login"
    print_error "  4. No ADO access — run: az devops login"
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

# Fetch all repositories in the project; sets global REPOS_JSON
fetch_repos() {
    print_info "Fetching repositories in project..."

    local repos_error
    repos_error=$(mktemp)

    local repos_response
    if ! repos_response=$(az rest \
        --method get \
        --uri "${AZDO_ORG}/${AZDO_PROJECT}/_apis/git/repositories?api-version=7.1" \
        --resource "$AZDO_RESOURCE" \
        2>"$repos_error"); then
        print_error "Failed to fetch repositories."
        cat "$repos_error"
        rm -f "$repos_error"
        return 1
    fi
    rm -f "$repos_error"

    if ! echo "$repos_response" | jq empty 2>/dev/null; then
        print_error "Invalid JSON response when fetching repositories:"
        echo "$repos_response"
        return 1
    fi

    REPOS_JSON="$repos_response"
}

# Present repo selection UI.
# Sets globals: SCOPE_MODE ("project"|"repos"), SELECTED_REPO_IDS[], SELECTED_REPO_NAMES[]
select_repos() {
    local repos_json="$1"

    # Parse repo list into parallel arrays
    local repo_ids=()
    local repo_names=()

    while IFS=$'\t' read -r rid rname; do
        repo_ids+=("$rid")
        repo_names+=("$rname")
    done < <(echo "$repos_json" | jq -r '.value[] | [.id, .name] | @tsv')

    local num_repos="${#repo_names[@]}"

    if [ "$num_repos" -eq 0 ]; then
        print_warn "No repositories found in project. Using project-wide scope."
        SCOPE_MODE="project"
        return 0
    fi

    echo ""
    print_info "Found $num_repos repositor$([ "$num_repos" -eq 1 ] && echo 'y' || echo 'ies') in project."

    # --- fzf path ---
    if command -v fzf &>/dev/null; then
        print_info "Use TAB to select multiple repos. Press ENTER to confirm."
        print_info "(Select 'ALL REPOS (project-wide)' to create project-wide subscriptions)"
        echo ""

        local fzf_input
        fzf_input=$(printf "ALL REPOS (project-wide)\n"; printf '%s\n' "${repo_names[@]}")

        local fzf_selection
        fzf_selection=$(echo "$fzf_input" | fzf --multi --prompt="Select repositories > " --header="TAB=multi-select  ENTER=confirm") || {
            print_error "No selection made. Exiting."
            exit 1
        }

        if echo "$fzf_selection" | grep -q "^ALL REPOS (project-wide)$"; then
            SCOPE_MODE="project"
            return 0
        fi

        SCOPE_MODE="repos"
        SELECTED_REPO_IDS=()
        SELECTED_REPO_NAMES=()

        while IFS= read -r selected_name; do
            for i in "${!repo_names[@]}"; do
                if [ "${repo_names[$i]}" = "$selected_name" ]; then
                    SELECTED_REPO_IDS+=("${repo_ids[$i]}")
                    SELECTED_REPO_NAMES+=("${repo_names[$i]}")
                    break
                fi
            done
        done <<< "$fzf_selection"

    # --- Numbered list fallback ---
    else
        print_warn "fzf not found. Using numbered list selection."
        echo ""
        echo "  0) ALL REPOS (project-wide)"
        for i in "${!repo_names[@]}"; do
            printf "  %d) %s\n" "$((i + 1))" "${repo_names[$i]}"
        done
        echo ""
        read -p "Enter comma-separated numbers (e.g. 0 or 1,3): " raw_input

        IFS=',' read -ra chosen_indices <<< "${raw_input// /}"

        for idx in "${chosen_indices[@]}"; do
            if [ "$idx" = "0" ]; then
                SCOPE_MODE="project"
                return 0
            fi
        done

        if [ "${#chosen_indices[@]}" -eq 0 ]; then
            print_error "No selection made. Exiting."
            exit 1
        fi

        SCOPE_MODE="repos"
        SELECTED_REPO_IDS=()
        SELECTED_REPO_NAMES=()

        for idx in "${chosen_indices[@]}"; do
            local arr_idx=$((idx - 1))
            if [ "$arr_idx" -ge 0 ] && [ "$arr_idx" -lt "$num_repos" ]; then
                SELECTED_REPO_IDS+=("${repo_ids[$arr_idx]}")
                SELECTED_REPO_NAMES+=("${repo_names[$arr_idx]}")
            else
                print_warn "Invalid selection '$idx' — skipping."
            fi
        done

        if [ "${#SELECTED_REPO_IDS[@]}" -eq 0 ]; then
            print_error "No valid repositories selected. Exiting."
            exit 1
        fi
    fi
}

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
    local repo_id="${3:-}"
    local repo_name="${4:-}"

    local scope_label
    if [ -n "$repo_id" ]; then
        scope_label=" [repo: $repo_name]"
    else
        scope_label=" [project-wide]"
    fi
    print_info "Creating webhook for event: $event_description ($event_type)${scope_label}..."
    
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
        "projectId": "$PROJECT_ID"$([ -n "$repo_id" ] && echo ",
        \"repository\": \"$repo_id\"")
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

# Fetch repositories and prompt user to select scope
REPOS_JSON=""
fetch_repos || exit 1

SCOPE_MODE="project"
SELECTED_REPO_IDS=()
SELECTED_REPO_NAMES=()

select_repos "$REPOS_JSON"

echo ""
if [ "$SCOPE_MODE" = "project" ]; then
    print_info "Scope: project-wide (all repositories)"
    print_info "Creating webhooks for ${#PR_EVENTS[@]} Pull Request events..."
else
    total_hooks=$(( ${#PR_EVENTS[@]} * ${#SELECTED_REPO_IDS[@]} ))
    print_info "Scope: ${#SELECTED_REPO_IDS[@]} repo(s) — ${SELECTED_REPO_NAMES[*]}"
    print_info "Creating $total_hooks webhook subscriptions (${#PR_EVENTS[@]} events × ${#SELECTED_REPO_IDS[@]} repos)..."
fi
echo ""

success_count=0
fail_count=0

if [ "$SCOPE_MODE" = "project" ]; then
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
else
    for i in "${!SELECTED_REPO_IDS[@]}"; do
        repo_id="${SELECTED_REPO_IDS[$i]}"
        repo_name="${SELECTED_REPO_NAMES[$i]}"

        print_info "--- Repository: $repo_name ---"
        for event_entry in "${PR_EVENTS[@]}"; do
            event_type="${event_entry%%:*}"
            event_desc="${event_entry##*:}"

            if create_webhook_subscription "$event_type" "$event_desc" "$repo_id" "$repo_name"; then
                ((success_count++))
            else
                ((fail_count++))
            fi
            echo ""
        done
    done
fi

# Summary
echo "=========================================="
print_info "Webhook creation complete!"
if [ "$SCOPE_MODE" = "project" ]; then
    print_info "Scope: project-wide"
else
    print_info "Scope: repos — ${SELECTED_REPO_NAMES[*]}"
fi
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
    echo "$SUBS_RESPONSE" | jq -r '
      .value[]
      | select(
          (.eventType | startswith("git.pullrequest")) or
          .eventType == "ms.vss-code.git-pullrequest-comment-event"
        )
      | "  - \(.eventType) | repo: \(.publisherInputs.repository // "all") | id: \(.id)"
    ' 2>/dev/null || print_warn "Could not parse subscriptions response"
else
    print_warn "Could not list subscriptions: $(cat "$SUBS_ERROR")"
fi
rm -f "$SUBS_ERROR"

exit $fail_count
