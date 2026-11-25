#!/bin/bash
# ==============================================================================
# Plotly Dash App - Local Setup & Google Cloud Run Deployment Script
# ==============================================================================
# What this script does:
#   1. Prompts you to pick an existing Google Cloud Project from a numbered list [1-N],
#      or easily create a brand new GCP project if none exist or desired.
#   2. Verifies Cloud Billing is enabled on the project (and links an active
#      billing account automatically if needed).
#   3. Enables the required Google Cloud APIs (Cloud Run, Artifact Registry,
#      Cloud Build, IAM, Cloud Logging, Cloud Storage).
#      - If you pass `--apis-only`, the script stops here so you can run locally
#        with `python3 main.py`.
#   4. Validates Python syntax across `main.py` and `examples/*.py`.
#   5. Grants IAM roles (Cloud Logging) to the Cloud Run service account.
#   6. Builds a container image via Google Cloud Build and deploys it to Cloud Run.
# ==============================================================================

# Exit immediately if any untested command exits with a non-zero status
set -e

# Force temporary directory to /tmp to avoid permission issues in restricted shells
export TMPDIR=/tmp

# ==============================================================================
# SECTION 1: Configuration & Default Flags
# ==============================================================================
REGION="us-central1"
REPO_NAME="dash-app-repo"
SERVICE_NAME="dse6000-final"
CONFIG_FILE="$HOME/.dash_gcp_template_deploy.json"

# Google Cloud APIs required by the application and deployment pipeline
REQUIRED_APIS=(
    "run.googleapis.com"               # Google Cloud Run (serverless container hosting)
    "artifactregistry.googleapis.com"  # Artifact Registry (stores built Docker images)
    "cloudbuild.googleapis.com"        # Cloud Build (builds Docker container in GCP)
    "storage.googleapis.com"           # Cloud Storage (staging buckets for Cloud Build)
    "iam.googleapis.com"               # Identity and Access Management (service account roles)
    "logging.googleapis.com"           # Cloud Logging (application & access logs)
)

# IAM roles required by the default Compute Engine / Cloud Run service account at runtime
REQUIRED_IAM_ROLES=(
    "roles/logging.logWriter"          # Allows writing container logs to Cloud Logging
)

# Default CLI option flags (can be overridden via command-line arguments in Section 3)
RUN_CHECKS=true
FORCE_REBUILD=false
ENABLE_APIS_ONLY=false
PROJECT_ID_OVERRIDE=""
BILLING_ACCOUNT_OVERRIDE=""
CREATE_PROJECT_REQUESTED=false
NEW_PROJECT_NAME_OVERRIDE=""

# Temporary paths cleaned up automatically when the script exits
ENV_YAML_FILE=""
cleanup_temp_files() {
    rm -rf "$ENV_YAML_FILE" 2>/dev/null || true
}
trap cleanup_temp_files EXIT

# ==============================================================================
# SECTION 2: CLI Help & Utility Functions
# ==============================================================================

# Prints usage instructions when `--help` / `-h` is passed
show_help() {
    echo "================================================================="
    echo "📊 Plotly Dash App - Cloud Run Build & Deploy Script"
    echo "================================================================="
    echo "Usage: ./run.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --project <id>          Deploy to a specific GCP Project ID (skips interactive menu)"
    echo "  --create-project [name] Interactively create a new GCP Project"
    echo "  --billing-account <id>  Link a specific Cloud Billing Account ID if billing is disabled"
    echo "  --apis-only             Only enable required Google Cloud APIs and exit"
    echo "  --skip-checks           Skip running local Python syntax validation"
    echo "  --force, --rebuild      Bypass all caches and force a full rebuild and redeploy"
    echo "  -f                      Short alias for --force"
    echo "  --help, -h              Display this reference and exit"
    echo ""
    echo "⚡ Smart Caching Behavior (stored in ~/.dash_gcp_template_deploy.json):"
    echo "  • GCP APIs & IAM: Skipped if already enabled for the selected project."
    echo "  • Container Build: Skipped if the source files SHA-256 hash has not"
    echo "    changed and the container image already exists in Artifact Registry."
    echo "  • Cloud Run Deploy: Skipped if neither the image nor env vars changed."
    echo "  • Project Switching: Cache automatically resets when switching projects."
    echo ""
    echo "Examples:"
    echo "  ./run.sh                         # Pick project [1-N], validate, build, and deploy"
    echo "  ./run.sh --create-project        # Create a new GCP project and deploy"
    echo "  ./run.sh --apis-only             # Pick project [1-N] and enable GCP APIs for local runs"
    echo "  ./run.sh --project my-gcp-proj   # Deploy directly to 'my-gcp-proj'"
    echo "  ./run.sh --force                 # Force complete rebuild and redeploy from scratch"
    echo "================================================================="
}

# Computes a combined SHA-256 checksum across project source files so we can
# detect whether the application code, dependencies, or Dockerfile changed.
get_source_sha256() {
    python3 - <<'PYEOF'
import hashlib
from pathlib import Path

hasher = hashlib.sha256()
files = [Path("Dockerfile"), Path("requirements.txt"), Path("main.py")]

for folder in ["data", "examples"]:
    p_dir = Path(folder)
    if p_dir.exists():
        files.extend(sorted(p for p in p_dir.rglob("*") if p.is_file()))

for path in files:
    if path.exists():
        hasher.update(str(path).encode("utf-8"))
        try:
            hasher.update(path.read_bytes())
        except Exception:
            pass

print(hasher.hexdigest())
PYEOF
}

# Computes the SHA-256 checksum of a single file
get_file_sha256() {
    local target_file="$1"
    if [ ! -f "$target_file" ]; then
        echo ""
        return
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$target_file" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$target_file" 2>/dev/null | awk '{print $1}'
    else
        python3 -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$target_file" 2>/dev/null
    fi
}

# Executes a shell command quietly, shows its log output only if an error occurs,
# and lets the user interactively Retry (1), Skip (2), or Abort (3) on failure.
LAST_STEP_SKIPPED=false
run_step() {
    local step_name="$1"
    local command="$2"
    LAST_STEP_SKIPPED=false

    echo "⚙️  Running: $step_name..."

    local log_file
    log_file=$(mktemp)
    set +e
    eval "$command" > "$log_file" 2>&1
    local exit_status=$?
    set -e

    if [ $exit_status -ne 0 ]; then
        echo "❌ Step failed! (Exit code: $exit_status)"
        echo "----------------------------------------"
        if [ -s "$log_file" ]; then cat "$log_file"; echo ""; fi
        echo "----------------------------------------"
        rm -f "$log_file"

        echo -e "\n1) Retry  2) Skip  3) Abort"
        read -p "Choice [1-3]: " fail_choice
        case $fail_choice in
            1) run_step "$step_name" "$command" ;;
            2) LAST_STEP_SKIPPED=true; return 0 ;;
            *) exit 1 ;;
        esac
    else
        echo "✅ Success!"
        rm -f "$log_file"
        echo ""
    fi
}

# ==============================================================================
# SECTION 3: Command-Line Argument Parsing
# ==============================================================================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --project|-p)
            if [ -n "$2" ] && [[ "$2" != --* ]]; then
                PROJECT_ID_OVERRIDE="$2"
                shift
            else
                echo "Error: --project requires a non-empty project ID argument."
                exit 1
            fi
            ;;
        --create-project)
            CREATE_PROJECT_REQUESTED=true
            if [ -n "$2" ] && [[ "$2" != --* ]]; then
                NEW_PROJECT_NAME_OVERRIDE="$2"
                shift
            fi
            ;;
        --billing-account|-b)
            if [ -n "$2" ] && [[ "$2" != --* ]]; then
                BILLING_ACCOUNT_OVERRIDE="${2#billingAccounts/}"
                shift
            else
                echo "Error: --billing-account requires a non-empty Billing Account ID."
                exit 1
            fi
            ;;
        --skip-checks|--skip-tests)
            RUN_CHECKS=false
            ;;
        --force|--rebuild|-f)
            FORCE_REBUILD=true
            ;;
        --apis-only)
            ENABLE_APIS_ONLY=true
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

echo "=================================================="
echo "📊 Plotly Dash App - Cloud Run Deployer"
echo "=================================================="
echo "Execution Plan:"
if [ "$ENABLE_APIS_ONLY" = true ]; then
    echo " - Mode: Enable Required Google Cloud APIs Only (--apis-only)"
else
    echo " - Local Validation (Syntax Check: $RUN_CHECKS)"
    echo " - Cloud Run Service: $SERVICE_NAME ($REGION)"
    [ "$FORCE_REBUILD" = true ] && echo " - Mode: Force Rebuild (Bypassing cache)"
fi
echo "=================================================="
echo ""

# ==============================================================================
# SECTION 4: Interactive GCP Project Selection & Creation
# ==============================================================================
CURRENT_GCLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)

create_new_project_flow() {
    local default_suffix=$((RANDOM % 90000 + 10000))
    local default_id="dash-gcp-${default_suffix}"
    
    echo ""
    echo "🆕 Creating a New Google Cloud Project"
    echo "--------------------------------------------------"
    read -p "👉 Enter Project ID (default: $default_id): " entered_id
    entered_id=$(echo "$entered_id" | xargs)
    local target_id="${entered_id:-$default_id}"

    local default_name="${NEW_PROJECT_NAME_OVERRIDE:-Plotly Dash App}"
    read -p "👉 Enter Project Display Name (default: $default_name): " entered_name
    entered_name=$(echo "$entered_name" | xargs)
    local target_name="${entered_name:-$default_name}"

    echo ""
    run_step "Create GCP Project '$target_id'" "gcloud projects create '$target_id' --name='$target_name' --quiet"
    PROJECT_ID="$target_id"
}

if [ -n "$PROJECT_ID_OVERRIDE" ]; then
    PROJECT_ID="$PROJECT_ID_OVERRIDE"
elif [ "$CREATE_PROJECT_REQUESTED" = true ]; then
    create_new_project_flow
else
    echo "🔍 Fetching available Google Cloud projects..."
    PROJECT_IDS=()
    PROJECT_NAMES=()
    while IFS=$'\t' read -r pid pname; do
        if [ -n "$pid" ]; then
            PROJECT_IDS+=("$pid")
            PROJECT_NAMES+=("$pname")
        fi
    done < <(gcloud projects list --filter="lifecycleState:ACTIVE" --format="value(projectId,name)" --sort-by=projectId 2>/dev/null)

    PROJECT_COUNT=${#PROJECT_IDS[@]}
    if [ "$PROJECT_COUNT" -eq 0 ]; then
        echo "⚠️  No active Google Cloud projects found."
        read -p "👉 Would you like to create a new GCP project now? [Y/n]: " CREATE_CHOICE
        CREATE_CHOICE=$(echo "$CREATE_CHOICE" | xargs)

        if [[ -z "$CREATE_CHOICE" || "$CREATE_CHOICE" =~ ^[Yy] ]]; then
            create_new_project_flow
        else
            read -p "👉 Please enter an existing target GCP Project ID manually: " PROJECT_ID
            PROJECT_ID=$(echo "$PROJECT_ID" | xargs)
        fi
    else
        echo ""
        echo "Available GCP Projects:"
        echo "--------------------------------------------------"
        for (( i=0; i<PROJECT_COUNT; i++ )); do
            idx=$((i + 1))
            marker=""
            if [ "${PROJECT_IDS[$i]}" = "$CURRENT_GCLOUD_PROJECT" ]; then
                marker=" [current]"
            fi
            printf "  %2d) %-32s (%s)%s\n" "$idx" "${PROJECT_IDS[$i]}" "${PROJECT_NAMES[$i]}" "$marker"
        done
        create_option=$((PROJECT_COUNT + 1))
        printf "  %2d) ➕ [Create a new GCP Project]\n" "$create_option"
        echo "--------------------------------------------------"
        read -p "👉 Select a project by number [1-$create_option]: " PROJECT_CHOICE
        PROJECT_CHOICE=$(echo "$PROJECT_CHOICE" | xargs)

        if [ "$PROJECT_CHOICE" = "$create_option" ]; then
            create_new_project_flow
        elif [[ "$PROJECT_CHOICE" =~ ^[0-9]+$ ]] && [ "$PROJECT_CHOICE" -ge 1 ] && [ "$PROJECT_CHOICE" -le "$PROJECT_COUNT" ]; then
            PROJECT_ID="${PROJECT_IDS[$((PROJECT_CHOICE - 1))]}"
        else
            echo "❌ Error: Invalid selection '$PROJECT_CHOICE'. Please enter a number between 1 and $create_option."
            exit 1
        fi
    fi
fi

if [ -z "$PROJECT_ID" ]; then
    echo "❌ Error: No GCP Project ID selected."
    exit 1
fi

# Export standard GCP project environment variables
export PROJECT_ID
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
export GOOGLE_CLOUD_PROJECT="$PROJECT_ID"
export GCP_PROJECT="$PROJECT_ID"
export GCLOUD_PROJECT="$PROJECT_ID"
export DEVSHELL_PROJECT_ID="$PROJECT_ID"

gcloud config set project "$PROJECT_ID" >/dev/null 2>&1

ACTIVE_ACCOUNT=$(gcloud config get-value account 2>/dev/null)
echo "Target GCP Project: $PROJECT_ID"
echo "Active Account:     $ACTIVE_ACCOUNT"
echo ""

# ==============================================================================
# SECTION 5: Smart Deployment Cache (~/.dash_gcp_template_deploy.json)
# ==============================================================================
APIS_INITIALIZED="false"
IAM_INITIALIZED="false"
INFRA_INITIALIZED="false"
LAST_DEPLOYED_PROJECT_ID=""
LAST_ENABLED_APIS=""
LAST_IAM_ROLES=""
LAST_SOURCE_HASH=""
LAST_ENV_HASH=""

save_config_state() {
    python3 -c "
import json, os

config_path = os.path.expanduser('$CONFIG_FILE')
data = {}
if os.path.exists(config_path):
    try:
        with open(config_path, 'r') as f:
            data = json.load(f)
    except Exception:
        data = {}

updates = {
    'LAST_DEPLOYED_PROJECT_ID': '$PROJECT_ID',
    'APIS_INITIALIZED': '$APIS_INITIALIZED',
    'IAM_INITIALIZED': '$IAM_INITIALIZED',
    'INFRA_INITIALIZED': '$INFRA_INITIALIZED',
    'LAST_ENABLED_APIS': '$LAST_ENABLED_APIS',
    'LAST_IAM_ROLES': '$LAST_IAM_ROLES',
    'LAST_SOURCE_HASH': '$LAST_SOURCE_HASH',
    'LAST_ENV_HASH': '$LAST_ENV_HASH'
}
data.update(updates)

with open(config_path, 'w') as f:
    json.dump(data, f, indent=4)
" 2>/dev/null || true
}

if [ -f "$CONFIG_FILE" ]; then
    eval "$(python3 -c "
import json, os
try:
    with open(os.path.expanduser('$CONFIG_FILE'), 'r') as f:
        config = json.load(f)
        for k, v in config.items():
            val = str(v).replace('\"', '\\\"') if v is not None else ''
            print(f'export {k}=\"{val}\"')
except Exception:
    pass
")"
fi

# Reset cached flags if switching GCP projects
if [ -n "$LAST_DEPLOYED_PROJECT_ID" ] && [ "$PROJECT_ID" != "$LAST_DEPLOYED_PROJECT_ID" ]; then
    echo "ℹ️  Switched GCP Project ($PROJECT_ID vs previous $LAST_DEPLOYED_PROJECT_ID). Resetting setup cache."
    APIS_INITIALIZED="false"
    IAM_INITIALIZED="false"
    INFRA_INITIALIZED="false"
    LAST_ENABLED_APIS=""
    LAST_IAM_ROLES=""
    LAST_SOURCE_HASH=""
    LAST_ENV_HASH=""
fi

# ==============================================================================
# SECTION 6: Cloud Billing Verification & Google Cloud API Enablement
# ==============================================================================
# Ensures an active Cloud Billing account is linked to $PROJECT_ID before
# enabling billing-gated services (Cloud Run, Artifact Registry, Cloud Build).
BILLING_CHECKED=false
ensure_billing_enabled() {
    if [ "$BILLING_CHECKED" = true ]; then
        return 0
    fi
    BILLING_CHECKED=true

    local billing_cmd="gcloud billing"
    if ! gcloud billing --help >/dev/null 2>&1; then
        billing_cmd="gcloud beta billing"
    fi

    local billing_json=""
    local describe_ok=false
    if billing_json=$($billing_cmd projects describe "$PROJECT_ID" --format="json" 2>/dev/null); then
        describe_ok=true
    fi

    if [ "$describe_ok" = true ]; then
        local is_enabled
        is_enabled=$(BILLING_JSON="$billing_json" python3 -c '
import json, os
try:
    data = json.loads(os.environ.get("BILLING_JSON", "{}") or "{}")
    print("true" if data.get("billingEnabled") is True else "false")
except Exception:
    print("unknown")
')
        if [ "$is_enabled" = "true" ]; then
            echo "⚡ Cloud Billing is active for $PROJECT_ID."
            return 0
        fi
    else
        # If billing info cannot be read (e.g., restricted role on shared project), proceed unless override provided
        if [ -z "$BILLING_ACCOUNT_OVERRIDE" ]; then
            return 0
        fi
    fi

    echo "⚠️  Cloud Billing is not enabled for project '$PROJECT_ID'."
    local selected_account="$BILLING_ACCOUNT_OVERRIDE"
    local selected_name=""

    if [ -z "$selected_account" ]; then
        echo "🔍 Checking available active Cloud Billing accounts..."
        local accounts_json="[]"
        accounts_json=$($billing_cmd accounts list --filter="open=true" --format="json" 2>/dev/null || echo "[]")

        local account_ids=()
        local account_names=()
        while IFS=$'\t' read -r aid aname; do
            if [ -n "$aid" ]; then
                account_ids+=("$aid")
                account_names+=("$aname")
            fi
        done < <(ACCOUNTS_JSON="$accounts_json" python3 -c '
import json, os
try:
    items = json.loads(os.environ.get("ACCOUNTS_JSON", "[]") or "[]")
    for item in items:
        if item.get("open") is False:
            continue
        raw_name = str(item.get("name", "")).strip()
        aid = raw_name.split("/")[-1] if raw_name else ""
        dname = str(item.get("displayName", "Billing Account")).replace("\t", " ").strip()
        if aid:
            print(f"{aid}\t{dname}")
except Exception:
    pass
')

        local account_count=${#account_ids[@]}
        if [ "$account_count" -eq 1 ]; then
            selected_account="${account_ids[0]}"
            selected_name="${account_names[0]}"
            echo "💳 Found active billing account: $selected_name ($selected_account)"
        elif [ "$account_count" -gt 1 ]; then
            echo ""
            echo "Available Active Cloud Billing Accounts:"
            echo "--------------------------------------------------"
            for (( i=0; i<account_count; i++ )); do
                idx=$((i + 1))
                printf "  %2d) %-24s (%s)\n" "$idx" "${account_ids[$i]}" "${account_names[$i]}"
            done
            echo "--------------------------------------------------"
            read -p "👉 Select a billing account to link to '$PROJECT_ID' [1-$account_count]: " billing_choice
            billing_choice=$(echo "$billing_choice" | xargs)
            if ! [[ "$billing_choice" =~ ^[0-9]+$ ]] || [ "$billing_choice" -lt 1 ] || [ "$billing_choice" -gt "$account_count" ]; then
                echo "❌ Error: Invalid selection '$billing_choice'. Please enter a number between 1 and $account_count."
                exit 1
            fi
            selected_account="${account_ids[$((billing_choice - 1))]}"
            selected_name="${account_names[$((billing_choice - 1))]}"
        else
            echo "⚠️  No active Cloud Billing accounts were found automatically."
            echo "   You can create or view your billing account at:"
            echo "     https://console.cloud.google.com/billing"
            echo "   Or link one directly in the Console for '$PROJECT_ID' at:"
            echo "     https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
            echo ""
            read -p "👉 Enter a Billing Account ID (e.g. 012345-6789AB-CDEF01), or press Enter if you linked it in browser: " manual_account
            selected_account=$(echo "$manual_account" | xargs)
            selected_account="${selected_account#billingAccounts/}"
        fi
    fi

    if [ -n "$selected_account" ]; then
        local label="$selected_account"
        if [ -n "$selected_name" ]; then
            label="$selected_name ($selected_account)"
        fi
        run_step "Link Cloud Billing Account ($label) to $PROJECT_ID" "$billing_cmd projects link '$PROJECT_ID' --billing-account='$selected_account' --quiet"
        if [ "$LAST_STEP_SKIPPED" = false ]; then
            sleep 2
        fi
    else
        local recheck_json=""
        recheck_json=$($billing_cmd projects describe "$PROJECT_ID" --format="json" 2>/dev/null || echo "{}")
        local now_enabled
        now_enabled=$(BILLING_JSON="$recheck_json" python3 -c '
import json, os
try:
    data = json.loads(os.environ.get("BILLING_JSON", "{}") or "{}")
    print("true" if data.get("billingEnabled") is True else "false")
except Exception:
    print("false")
')
        if [ "$now_enabled" != "true" ]; then
            echo "❌ Error: Cloud Billing is still not enabled for '$PROJECT_ID'. Billing is required to activate Cloud Run, Artifact Registry, and Cloud Build APIs."
            exit 1
        fi
        echo "✅ Confirmed Cloud Billing is now active for $PROJECT_ID!"
        echo ""
    fi
}

# Verify billing upfront when setting up a new/switched project
if [ "$APIS_INITIALIZED" != "true" ] || [ "$FORCE_REBUILD" = true ] || [ -n "$BILLING_ACCOUNT_OVERRIDE" ]; then
    ensure_billing_enabled
fi

# Enables missing Google Cloud APIs automatically
enable_required_apis() {
    local required_apis_str="${REQUIRED_APIS[*]}"

    if [ "$FORCE_REBUILD" = true ]; then
        ensure_billing_enabled
        run_step "Enable Google Cloud APIs" "gcloud services enable ${REQUIRED_APIS[*]} --project=$PROJECT_ID --quiet"
        if [ "$LAST_STEP_SKIPPED" = false ]; then
            APIS_INITIALIZED="true"
            LAST_ENABLED_APIS="$required_apis_str"
            save_config_state
        fi
        return
    fi

    local enabled_apis
    if ! enabled_apis=$(gcloud services list --enabled --project="$PROJECT_ID" --format="value(config.name)" --quiet 2>/dev/null); then
        ensure_billing_enabled
        run_step "Enable Google Cloud APIs" "gcloud services enable ${REQUIRED_APIS[*]} --project=$PROJECT_ID --quiet"
        if [ "$LAST_STEP_SKIPPED" = false ]; then
            APIS_INITIALIZED="true"
            LAST_ENABLED_APIS="$required_apis_str"
            save_config_state
        fi
        return
    fi

    local missing_apis=()
    for api in "${REQUIRED_APIS[@]}"; do
        if ! printf '%s\n' "$enabled_apis" | grep -Fxq "$api"; then
            missing_apis+=("$api")
        fi
    done

    if [ "${#missing_apis[@]}" -eq 0 ]; then
        echo "⚡ All required Google Cloud APIs are enabled for $PROJECT_ID."
        if [ "$APIS_INITIALIZED" != "true" ] || [ "$LAST_ENABLED_APIS" != "$required_apis_str" ]; then
            APIS_INITIALIZED="true"
            LAST_ENABLED_APIS="$required_apis_str"
            save_config_state
        fi
    else
        echo "ℹ️  Missing required API(s) on $PROJECT_ID: ${missing_apis[*]}"
        ensure_billing_enabled
        run_step "Enable Missing Google Cloud APIs (${missing_apis[*]})" "gcloud services enable ${missing_apis[*]} --project=$PROJECT_ID --quiet"
        if [ "$LAST_STEP_SKIPPED" = false ]; then
            APIS_INITIALIZED="true"
            LAST_ENABLED_APIS="$required_apis_str"
            save_config_state
        fi
    fi
}

# If the user ran `./run.sh --apis-only` (for local development), enable APIs and exit now
if [ "$ENABLE_APIS_ONLY" = true ]; then
    echo "=== Enabling Required Google Cloud APIs for $PROJECT_ID ==="
    enable_required_apis
    echo "=========================================="
    echo "🎉 Google Cloud APIs Ready for $PROJECT_ID! 🎉"
    echo "=========================================="
    exit 0
fi

# ==============================================================================
# SECTION 7: Step 1 — Local Python Validation
# ==============================================================================
echo "=== Step 1: Validating Python Application ==="
if [ "$RUN_CHECKS" = true ]; then
    run_step "Validate Python Syntax" "python3 -m py_compile main.py examples/*.py"
else
    echo "⚠️  Skipping Python syntax validation (--skip-checks active)"
    echo ""
fi

# ==============================================================================
# SECTION 8: Step 2 — Google Cloud APIs & Service Account IAM Permissions
# ==============================================================================
echo "=== Step 2: Google Cloud APIs & IAM Permissions ==="
enable_required_apis

# Look up default Compute Engine service account used by Cloud Run
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

CURRENT_IAM_ROLES="${REQUIRED_IAM_ROLES[*]}"
if [ "$FORCE_REBUILD" = false ] && [ "$IAM_INITIALIZED" = "true" ] && [ "$PROJECT_ID" = "$LAST_DEPLOYED_PROJECT_ID" ] && [ "$LAST_IAM_ROLES" = "$CURRENT_IAM_ROLES" ]; then
    echo "⚡ IAM permissions already configured for $DEFAULT_SA (use --force to re-verify)."
else
    IAM_CMD=""
    for role in "${REQUIRED_IAM_ROLES[@]}"; do
        if [ -n "$IAM_CMD" ]; then
            IAM_CMD="$IAM_CMD && "
        fi
        IAM_CMD="${IAM_CMD}gcloud projects add-iam-policy-binding $PROJECT_ID --member='serviceAccount:$DEFAULT_SA' --role='$role' --quiet"
    done
    run_step "Grant Cloud Logging IAM Role" "$IAM_CMD"
    if [ "$LAST_STEP_SKIPPED" = false ]; then
        IAM_INITIALIZED="true"
        LAST_IAM_ROLES="$CURRENT_IAM_ROLES"
        save_config_state
    fi
fi

# ==============================================================================
# SECTION 9: Step 3A — Container Image Build (Artifact Registry & Cloud Build)
# ==============================================================================
echo "=== Step 3: Cloud Run Deployment ==="

# 1. Ensure the Docker repository exists in Artifact Registry
if [ "$FORCE_REBUILD" = false ] && [ "$INFRA_INITIALIZED" = "true" ] && [ "$PROJECT_ID" = "$LAST_DEPLOYED_PROJECT_ID" ]; then
    echo "⚡ Artifact Registry repository ($REPO_NAME) already initialized."
else
    run_step "Create Artifact Registry Repository" "gcloud artifacts repositories create $REPO_NAME --repository-format=docker --location=$REGION --project=$PROJECT_ID || true"
    INFRA_INITIALIZED="true"
    save_config_state
fi

# 2. Generate runtime environment variables file for the Cloud Run service
ENV_YAML_FILE="/tmp/dash_gcp_env.yaml"
cat <<EOF > "$ENV_YAML_FILE"
GCP_PROJECT: "$PROJECT_ID"
GOOGLE_CLOUD_PROJECT: "$PROJECT_ID"
EOF

CURRENT_SOURCE_HASH=$(get_source_sha256)
CURRENT_ENV_HASH=$(get_file_sha256 "$ENV_YAML_FILE")
IMAGE_TAG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${SERVICE_NAME}:latest"

# 3. Check if the container image already exists in Artifact Registry
IMAGE_EXISTS=false
if gcloud artifacts docker images describe "$IMAGE_TAG" --project "$PROJECT_ID" --format='value(image_summary.digest)' >/dev/null 2>&1; then
    IMAGE_EXISTS=true
fi

NEED_CONTAINER_BUILD=true
if [ "$FORCE_REBUILD" = false ] && [ "$IMAGE_EXISTS" = true ] && [ -n "$CURRENT_SOURCE_HASH" ] && [ "$CURRENT_SOURCE_HASH" = "$LAST_SOURCE_HASH" ]; then
    NEED_CONTAINER_BUILD=false
fi

if [ "$NEED_CONTAINER_BUILD" = true ]; then
    run_step "Ensure Cloud Build Staging Bucket" "gcloud storage buckets create gs://${PROJECT_ID}_cloudbuild --location=$REGION --project=$PROJECT_ID || true"
    run_step "Build Container Image via Cloud Build" "gcloud builds submit . --tag $IMAGE_TAG --project $PROJECT_ID"
    LAST_SOURCE_HASH="$CURRENT_SOURCE_HASH"
    save_config_state
else
    echo "⚡ Application source files and container image are unchanged."
    echo "   ⏩ Skipping Cloud Build container build (use --force to rebuild)."
fi

# ==============================================================================
# SECTION 10: Step 3B — Cloud Run Service Deployment & URL Output
# ==============================================================================
SERVICE_ACTIVE=false
if gcloud run services describe "$SERVICE_NAME" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)' >/dev/null 2>&1; then
    SERVICE_ACTIVE=true
fi

NEED_RUN_DEPLOY=true
if [ "$FORCE_REBUILD" = false ] && [ "$NEED_CONTAINER_BUILD" = false ] && [ "$SERVICE_ACTIVE" = true ] && [ -n "$CURRENT_ENV_HASH" ] && [ "$CURRENT_ENV_HASH" = "$LAST_ENV_HASH" ]; then
    NEED_RUN_DEPLOY=false
fi

if [ "$NEED_RUN_DEPLOY" = true ]; then
    DEPLOY_CMD="gcloud run deploy $SERVICE_NAME \
        --image $IMAGE_TAG \
        --region $REGION \
        --project $PROJECT_ID \
        --allow-unauthenticated \
        --env-vars-file $ENV_YAML_FILE \
        --concurrency=80 \
        --memory=1Gi \
        --cpu=1 \
        --min-instances=0 \
        --max-instances=5 \
        --timeout=300"
    run_step "Deploy Service to Cloud Run" "$DEPLOY_CMD"
    LAST_ENV_HASH="$CURRENT_ENV_HASH"
    save_config_state
else
    echo "⚡ Cloud Run service ($SERVICE_NAME) is already active with up-to-date configuration. Skipping deployment."
fi

SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)' 2>/dev/null)

echo "=========================================="
echo "🎉 Deployment Process Completed! 🎉"
echo "=========================================="
echo "Project: $PROJECT_ID"
echo "Service: $SERVICE_NAME ($REGION)"
echo "URL:     $SERVICE_URL"
echo "=========================================="
