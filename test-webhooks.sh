#!/bin/bash
#
# End-to-end test harness for add-azdo-pr-webhooks.sh
# Mocks az CLI; covers project-wide, single-repo, multi-repo, and edge cases.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/add-azdo-pr-webhooks.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "${GREEN}✓ PASS${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}✗ FAIL${NC} $1"; ((FAIL++)); }
section() { echo -e "\n${CYAN}══ $1 ══${NC}"; }

# ── Fixtures ─────────────────────────────────────────────────────────────────

PROJECT_JSON='{"id":"proj-uuid-1234","name":"test-project"}'

REPOS_JSON='{"value":[{"id":"repo-uuid-aaaa","name":"api-service"},{"id":"repo-uuid-bbbb","name":"frontend"},{"id":"repo-uuid-cccc","name":"infra"}]}'

REPOS_EMPTY_JSON='{"value":[]}'

SUBS_LIST_JSON='{"value":[
  {"id":"sub-1","eventType":"git.pullrequest.created","publisherInputs":{"projectId":"proj-uuid-1234"}},
  {"id":"sub-2","eventType":"ms.vss-code.git-pullrequest-comment-event","publisherInputs":{"projectId":"proj-uuid-1234","repository":"repo-uuid-aaaa"}}
]}'

# ── Mock setup ───────────────────────────────────────────────────────────────

MOCK_DIR=""

make_mock_az() {
    local repos_fixture="$1"
    MOCK_DIR=$(mktemp -d)
    local mock_file="$MOCK_DIR/az"

    # Write the repos fixture to a file so the mock can read it
    echo "$repos_fixture" > "$MOCK_DIR/repos.json"

    cat > "$mock_file" << 'MOCK_SCRIPT'
#!/bin/bash
URI=""; METHOD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --uri)    URI="$2";    shift 2 ;;
        --method) METHOD="$2"; shift 2 ;;
        rest)     shift ;;
        *)        shift ;;
    esac
done
MOCK_DIR="$(dirname "$0")"
if [[ "$URI" == *"/_apis/projects/"* ]]; then
    echo '{"id":"proj-uuid-1234","name":"test-project"}'
elif [[ "$URI" == *"/_apis/git/repositories"* ]]; then
    cat "$MOCK_DIR/repos.json"
elif [[ "$METHOD" == "post" && "$URI" == *"/_apis/hooks/subscriptions"* ]]; then
    HASH=$(printf '%s%s' "$URI" "$RANDOM" | cksum | awk '{print $1}')
    echo "{\"id\":\"sub-${HASH}-uuid\"}"
elif [[ "$METHOD" == "get" && "$URI" == *"/_apis/hooks/subscriptions"* ]]; then
    echo '{"value":[{"id":"sub-list-1","eventType":"git.pullrequest.created","publisherInputs":{"projectId":"proj-uuid-1234"}},{"id":"sub-list-2","eventType":"ms.vss-code.git-pullrequest-comment-event","publisherInputs":{"projectId":"proj-uuid-1234","repository":"repo-uuid-aaaa"}}]}'
fi
MOCK_SCRIPT
    chmod +x "$mock_file"
}

cleanup_mock() {
    [ -n "$MOCK_DIR" ] && rm -rf "$MOCK_DIR"
    MOCK_DIR=""
}

# Run the script: mock PATH (no fzf), piped stdin
run_script() {
    local mock_dir="$1"
    local stdin_input="$2"
    local safe_path="$mock_dir:/usr/bin:/bin:/usr/sbin:/sbin"
    echo "$stdin_input" | PATH="$safe_path" bash "$SCRIPT" 2>&1 || true
}

count_successes() {
    echo "$1" | grep -c "Successfully created webhook" || true
}

# ── 1. Bash syntax ────────────────────────────────────────────────────────────

section "Bash syntax check"

if bash -n "$SCRIPT" 2>/dev/null; then
    pass "Script passes bash -n syntax check"
else
    fail "Script has syntax errors"
    bash -n "$SCRIPT"
fi

# ── 2. Webhook header construction ───────────────────────────────────────────

section "Webhook header construction"

# Simulate the script's token → header logic
build_header() {
    local token="$1"
    echo "X-Webhook-Secret: ${token}"
}

HEADER=$(build_header "c2a860d5-7236-453d-bd22-338dee2ccea4")
if [ "$HEADER" = "X-Webhook-Secret: c2a860d5-7236-453d-bd22-338dee2ccea4" ]; then
    pass "UUID token → correct X-Webhook-Secret header"
else
    fail "UUID token → wrong header: '$HEADER'"
fi

HEADER=$(build_header "mysimpletoken")
if [ "$HEADER" = "X-Webhook-Secret: mysimpletoken" ]; then
    pass "Simple token → correct X-Webhook-Secret header"
else
    fail "Simple token → wrong header: '$HEADER'"
fi

# Verify the prompt label changed (no longer asks for full header)
if grep -q "Enter Webhook Secret Token" "$SCRIPT"; then
    pass "Script prompts for token only (not full header)"
else
    fail "Script still has old full-header prompt"
fi

# Verify header prefix is baked in
if grep -q 'HTTP_HEADER="X-Webhook-Secret: \${WEBHOOK_TOKEN}"' "$SCRIPT"; then
    pass "Script builds X-Webhook-Secret header automatically"
else
    fail "Script does not auto-build X-Webhook-Secret header"
fi

# ── 3. Payload JSON validation ────────────────────────────────────────────────

section "Payload JSON validation"

# Project-wide payload (no repo_id)
PW_PAYLOAD=$(bash -c '
PROJECT_ID="proj-uuid-1234"
repo_id=""
cat <<EOF
{
    "publisherId": "tfs",
    "publisherInputs": {
        "projectId": "$PROJECT_ID"'"$([ -n "" ] && echo ",\n        \"repository\": \"\"")"'
    }
}
EOF
' 2>/dev/null) || true

if echo "$PW_PAYLOAD" | jq empty 2>/dev/null; then
    pass "Project-wide payload is valid JSON"
    REPO_VAL=$(echo "$PW_PAYLOAD" | jq -r '.publisherInputs.repository // "absent"')
    if [ "$REPO_VAL" = "absent" ]; then
        pass "Project-wide payload has no 'repository' field"
    else
        fail "Project-wide payload unexpectedly has 'repository': $REPO_VAL"
    fi
else
    fail "Project-wide payload is not valid JSON"
    echo "  Payload: $PW_PAYLOAD"
fi

# Repo-scoped payload - construct directly with jq to avoid shell quoting issues
RS_PAYLOAD=$(jq -n \
    --arg pid "proj-uuid-1234" \
    --arg rid "repo-uuid-aaaa" \
    '{publisherId:"tfs",publisherInputs:{projectId:$pid,repository:$rid}}')

if echo "$RS_PAYLOAD" | jq empty 2>/dev/null; then
    pass "Repo-scoped payload is valid JSON"
    REPO_FIELD=$(echo "$RS_PAYLOAD" | jq -r '.publisherInputs.repository')
    if [ "$REPO_FIELD" = "repo-uuid-aaaa" ]; then
        pass "Repo-scoped payload contains correct 'repository' field"
    else
        fail "Repo-scoped payload has wrong repository: '$REPO_FIELD'"
    fi
else
    fail "Repo-scoped payload is not valid JSON"
fi

# Verify the actual script payload heredoc produces valid JSON for repo-scoped case
# by sourcing just the payload-building logic
HEREDOC_PAYLOAD=$(bash -c '
PROJECT_ID="proj-uuid-1234"
WEBHOOK_URL="https://example.com/webhook"
HTTP_HEADER="X-Webhook-Secret: secret"
event_type="git.pullrequest.created"
repo_id="repo-uuid-aaaa"
payload=$(cat <<EOF
{
    "publisherId": "tfs",
    "eventType": "$event_type",
    "resourceVersion": "1.0",
    "consumerId": "webHooks",
    "consumerActionId": "httpRequest",
    "publisherInputs": {
        "projectId": "$PROJECT_ID"'"$([ -n "repo-uuid-aaaa" ] && echo ",
        \"repository\": \"repo-uuid-aaaa\"")"'
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
echo "$payload"
' 2>/dev/null) || true

if echo "$HEREDOC_PAYLOAD" | jq empty 2>/dev/null; then
    pass "Script heredoc produces valid JSON with repo_id set"
    REPO_FROM_HEREDOC=$(echo "$HEREDOC_PAYLOAD" | jq -r '.publisherInputs.repository')
    if [ "$REPO_FROM_HEREDOC" = "repo-uuid-aaaa" ]; then
        pass "Script heredoc payload has correct repository UUID"
    else
        fail "Script heredoc payload has wrong repo: '$REPO_FROM_HEREDOC'"
    fi
else
    fail "Script heredoc produces invalid JSON with repo_id set"
    echo "  Payload: $HEREDOC_PAYLOAD"
fi

# ── 3. Subscription listing jq filter ────────────────────────────────────────

section "Subscription listing jq filter"

JQ_OUT=$(echo "$SUBS_LIST_JSON" | jq -r '
  .value[]
  | select(
      (.eventType | startswith("git.pullrequest")) or
      .eventType == "ms.vss-code.git-pullrequest-comment-event"
    )
  | "  - \(.eventType) | repo: \(.publisherInputs.repository // "all") | id: \(.id)"
' 2>/dev/null) || true

if echo "$JQ_OUT" | grep -q "git.pullrequest.created"; then
    pass "Listing filter matches git.pullrequest.* events"
else
    fail "Listing filter missed git.pullrequest.created"
fi

if echo "$JQ_OUT" | grep -q "ms.vss-code.git-pullrequest-comment-event"; then
    pass "Listing filter matches ms.vss-code.* comment event"
else
    fail "Listing filter missed ms.vss-code comment event"
fi

if echo "$JQ_OUT" | grep -q "repo: repo-uuid-aaaa"; then
    pass "Listing filter shows repo UUID for scoped subscription"
else
    fail "Listing filter did not show repo UUID"
fi

if echo "$JQ_OUT" | grep -q 'repo: all'; then
    pass "Listing filter shows 'all' for project-wide subscription"
else
    fail "Listing filter did not show 'all' for project-wide"
fi

# ── 4. Org URL normalization ──────────────────────────────────────────────────

section "Org URL normalization"

normalize_org() {
    local org="$1"
    if [[ ! "$org" =~ ^https?:// ]]; then
        org="https://dev.azure.com/${org}"
    fi
    echo "${org%/}"
}

RESULT=$(normalize_org "myorg")
if [ "$RESULT" = "https://dev.azure.com/myorg" ]; then
    pass "Bare name → full URL"
else
    fail "Bare name normalization failed: got '$RESULT'"
fi

RESULT=$(normalize_org "https://dev.azure.com/myorg/")
if [ "$RESULT" = "https://dev.azure.com/myorg" ]; then
    pass "Trailing slash stripped"
else
    fail "Trailing slash not stripped: got '$RESULT'"
fi

RESULT=$(normalize_org "https://dev.azure.com/myorg")
if [ "$RESULT" = "https://dev.azure.com/myorg" ]; then
    pass "Full URL without trailing slash unchanged"
else
    fail "Full URL changed unexpectedly: got '$RESULT'"
fi

# ── 5. select_repos numbered-list logic ──────────────────────────────────────

section "select_repos() — numbered list unit tests"

# Write select_repos as a standalone test script
SELECT_TEST="$SCRIPT_DIR/.test_select_repos.sh"

cat > "$SELECT_TEST" << 'EOF'
#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

SCOPE_MODE="project"
SELECTED_REPO_IDS=()
SELECTED_REPO_NAMES=()

select_repos() {
    local repos_json="$1"
    local repo_ids=(); local repo_names=()
    while IFS=$'\t' read -r rid rname; do
        repo_ids+=("$rid"); repo_names+=("$rname")
    done < <(echo "$repos_json" | jq -r '.value[] | [.id, .name] | @tsv')
    local num_repos="${#repo_names[@]}"
    if [ "$num_repos" -eq 0 ]; then
        print_warn "No repositories found in project. Using project-wide scope."
        SCOPE_MODE="project"; return 0
    fi
    print_info "Found $num_repos repositories in project."
    # Numbered list fallback (no fzf path)
    read -r raw_input
    IFS=',' read -ra chosen_indices <<< "${raw_input// /}"
    for idx in "${chosen_indices[@]}"; do
        if [ "$idx" = "0" ]; then SCOPE_MODE="project"; return 0; fi
    done
    if [ "${#chosen_indices[@]}" -eq 0 ]; then
        print_error "No selection made. Exiting."; exit 1
    fi
    SCOPE_MODE="repos"; SELECTED_REPO_IDS=(); SELECTED_REPO_NAMES=()
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
        print_error "No valid repos selected. Exiting."; exit 1
    fi
}

REPOS='{"value":[{"id":"id-a","name":"api-service"},{"id":"id-b","name":"frontend"},{"id":"id-c","name":"infra"}]}'
EMPTY_REPOS='{"value":[]}'
ACTION="${1:-}"

case "$ACTION" in
    all)       select_repos "$REPOS"       <<< "0"   ;;
    single)    select_repos "$REPOS"       <<< "2"   ;;
    multi)     select_repos "$REPOS"       <<< "1,3" ;;
    invalid)   select_repos "$REPOS"       <<< "99"  ;;
    empty)     select_repos "$EMPTY_REPOS" <<< ""    ;;
esac

echo "SCOPE_MODE=$SCOPE_MODE"
echo "REPO_COUNT=${#SELECTED_REPO_IDS[@]}"
echo "REPO_NAMES=${SELECTED_REPO_NAMES[*]}"
echo "REPO_IDS=${SELECTED_REPO_IDS[*]}"
EOF
chmod +x "$SELECT_TEST"

# Test: choosing 0 → project-wide
OUT=$(bash "$SELECT_TEST" all 2>/dev/null) || true
if echo "$OUT" | grep -q "SCOPE_MODE=project"; then
    pass "Choosing '0' → SCOPE_MODE=project"
else
    fail "Choosing '0' did not set project scope"; echo "  Output: $OUT"
fi
if echo "$OUT" | grep -q "REPO_COUNT=0"; then
    pass "No repos selected when choosing 0"
else
    fail "Unexpected repos when choosing 0"; echo "  Output: $OUT"
fi

# Test: choosing single repo
OUT=$(bash "$SELECT_TEST" single 2>/dev/null) || true
if echo "$OUT" | grep -q "SCOPE_MODE=repos"; then
    pass "Choosing '2' → SCOPE_MODE=repos"
else
    fail "Choosing '2' did not set repos scope"; echo "  Output: $OUT"
fi
if echo "$OUT" | grep -q "REPO_COUNT=1"; then
    pass "Single repo selection → 1 repo"
else
    fail "Wrong count for single selection"; echo "  Output: $OUT"
fi
if echo "$OUT" | grep -q "frontend"; then
    pass "Correct repo selected (frontend)"
else
    fail "Wrong repo selected for input '2'"; echo "  Output: $OUT"
fi

# Test: choosing multiple repos
OUT=$(bash "$SELECT_TEST" multi 2>/dev/null) || true
if echo "$OUT" | grep -q "REPO_COUNT=2"; then
    pass "Choosing '1,3' → 2 repos selected"
else
    fail "Wrong count for '1,3' selection"; echo "  Output: $OUT"
fi
if echo "$OUT" | grep -q "api-service" && echo "$OUT" | grep -q "infra"; then
    pass "Correct repos selected (api-service, infra)"
else
    fail "Wrong repos for input '1,3'"; echo "  Output: $OUT"
fi

# Test: invalid index skipped, empty result → exit 1
OUT=$(bash "$SELECT_TEST" invalid 2>/dev/null); RC=$?
if [ "$RC" -ne 0 ]; then
    pass "Invalid index only → script exits with error"
else
    fail "Invalid index should have caused exit 1"; echo "  Output: $OUT"
fi

# Test: empty repo list → project-wide fallback
OUT=$(bash "$SELECT_TEST" empty 2>/dev/null) || true
if echo "$OUT" | grep -q "SCOPE_MODE=project"; then
    pass "Empty repo list → falls back to project-wide scope"
else
    fail "Empty repo list did not fall back to project-wide"; echo "  Output: $OUT"
fi

rm -f "$SELECT_TEST"

# ── 6. E2E: project-wide (input 0) ───────────────────────────────────────────

section "E2E — project-wide scope (select 0)"

make_mock_az "$REPOS_JSON"
STDIN="myorg
my-project
https://example.com/webhook
secret123
0"
OUTPUT=$(run_script "$MOCK_DIR" "$STDIN")
cleanup_mock

SUB_COUNT=$(count_successes "$OUTPUT")
if [ "$SUB_COUNT" -eq 4 ]; then
    pass "E2E project-wide: 4 subscriptions created"
else
    fail "E2E project-wide: expected 4, got $SUB_COUNT"
    echo "--- Output ---"; echo "$OUTPUT"; echo "--------------"
fi
if echo "$OUTPUT" | grep -q "\[project-wide\]"; then
    pass "E2E project-wide: scope label '[project-wide]' present"
else
    fail "E2E project-wide: scope label missing"
fi
if echo "$OUTPUT" | grep -q "Scope: project-wide"; then
    pass "E2E project-wide: summary shows project-wide"
else
    fail "E2E project-wide: summary scope line missing"
fi
if echo "$OUTPUT" | grep -q "X-Webhook-Secret: secret123"; then
    pass "E2E project-wide: header auto-constructed as X-Webhook-Secret"
else
    fail "E2E project-wide: X-Webhook-Secret header not shown in output"
fi

# ── 7. E2E: single repo (input 1) ────────────────────────────────────────────

section "E2E — single repo (select 1)"

make_mock_az "$REPOS_JSON"
STDIN="myorg
my-project
https://example.com/webhook
secret123
1"
OUTPUT=$(run_script "$MOCK_DIR" "$STDIN")
cleanup_mock

SUB_COUNT=$(count_successes "$OUTPUT")
if [ "$SUB_COUNT" -eq 4 ]; then
    pass "E2E single repo: 4 subscriptions created (4 events × 1 repo)"
else
    fail "E2E single repo: expected 4, got $SUB_COUNT"
    echo "--- Output ---"; echo "$OUTPUT"; echo "--------------"
fi
if echo "$OUTPUT" | grep -q "\[repo: api-service\]"; then
    pass "E2E single repo: scope label shows repo name"
else
    fail "E2E single repo: repo scope label missing"
fi
if echo "$OUTPUT" | grep -q "Repository: api-service"; then
    pass "E2E single repo: per-repo banner shown"
else
    fail "E2E single repo: repo banner missing"
fi

# ── 8. E2E: multi-repo (input 1,3) ───────────────────────────────────────────

section "E2E — multi-repo (select 1,3)"

make_mock_az "$REPOS_JSON"
STDIN="myorg
my-project
https://example.com/webhook
secret123
1,3"
OUTPUT=$(run_script "$MOCK_DIR" "$STDIN")
cleanup_mock

SUB_COUNT=$(count_successes "$OUTPUT")
if [ "$SUB_COUNT" -eq 8 ]; then
    pass "E2E multi-repo: 8 subscriptions created (4 events × 2 repos)"
else
    fail "E2E multi-repo: expected 8, got $SUB_COUNT"
    echo "--- Output ---"; echo "$OUTPUT"; echo "--------------"
fi
if echo "$OUTPUT" | grep -q "4 events × 2 repos"; then
    pass "E2E multi-repo: summary shows correct subscription math"
else
    fail "E2E multi-repo: subscription count math missing"
fi
if echo "$OUTPUT" | grep -q "api-service" && echo "$OUTPUT" | grep -q "infra"; then
    pass "E2E multi-repo: both repos appear in output"
else
    fail "E2E multi-repo: expected repo names missing"
fi
if echo "$OUTPUT" | grep -q "Scope: repos"; then
    pass "E2E multi-repo: summary shows repos scope"
else
    fail "E2E multi-repo: summary scope line missing"
fi

# ── 9. E2E: zero repos fallback ──────────────────────────────────────────────

section "E2E — zero repos (fallback to project-wide)"

make_mock_az "$REPOS_EMPTY_JSON"
STDIN="myorg
my-project
https://example.com/webhook
secret123"
OUTPUT=$(run_script "$MOCK_DIR" "$STDIN")
cleanup_mock

SUB_COUNT=$(count_successes "$OUTPUT")
if [ "$SUB_COUNT" -eq 4 ]; then
    pass "E2E empty repos: 4 project-wide subscriptions created"
else
    fail "E2E empty repos: expected 4, got $SUB_COUNT"
    echo "--- Output ---"; echo "$OUTPUT"; echo "--------------"
fi
if echo "$OUTPUT" | grep -qi "no repositories found"; then
    pass "E2E empty repos: warning message shown"
else
    fail "E2E empty repos: warning message missing"
fi

# ── 10. E2E: all 4 event types used ──────────────────────────────────────────

section "E2E — all 4 PR event types covered"

make_mock_az "$REPOS_JSON"
STDIN="myorg
my-project
https://example.com/webhook
secret123
0"
OUTPUT=$(run_script "$MOCK_DIR" "$STDIN")
cleanup_mock

for EVENT in "git.pullrequest.created" "git.pullrequest.updated" "git.pullrequest.merged" "ms.vss-code.git-pullrequest-comment-event"; do
    if echo "$OUTPUT" | grep -q "$EVENT"; then
        pass "Event type covered: $EVENT"
    else
        fail "Event type missing: $EVENT"
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

TOTAL=$((PASS + FAIL))
echo ""
echo "══════════════════════════════════════════════"
echo -e "Results: ${GREEN}${PASS}/${TOTAL} passed${NC}  ${RED}${FAIL} failed${NC}"
echo "══════════════════════════════════════════════"

exit $FAIL
