#!/bin/bash
# ==============================================================================
# Plotly Dash App - Local API Setup & Google Cloud Run Deployment Script
# ==============================================================================
# What this script does:
#   1. Prompts you to pick a Google Cloud Project from a numbered list [1-N].
#   2. Enables the required Google Cloud APIs (Cloud Run, Artifact Registry,
#      Cloud Build, IAM, and Cloud Logging).
#      - If you pass `--apis-only`, the script stops here so you can run locally
#        with `python3 main.py`.
#   3. Validates Python syntax across `main.py` and `examples/*.py`.
#   4. Grants IAM roles (Cloud Logging) to the Cloud Run service account.
#   5. Builds a container image via Google Cloud Build and deploys it to Cloud Run.
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
SERVICE_NAME="dash-gcp-app"
CONFIG_FILE="$HOME/.dash_gcp_template_deploy.json"

# Google Cloud APIs required by the application and deployment pipeline
REQUIRED_APIS=(
    "run.googleapis.com"               # Google Cloud Run (serverless container hosting)
    "artifactregistry.googleapis.com"  # Artifact Registry (stores built Docker images)
    "cloudbuild.googleapis.com"        # Cloud Build (builds the Docker container in GCP)
    "iam.googleapis.com"               # Identity and Access Management (service account roles)
    "logging.googleapis.com"           # Cloud Logging (application logs)
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
    echo "  --project <id>     Deploy to a specific GCP Project ID (skips interactive menu)"
    echo "  --apis-only        Only enable required Google Cloud APIs and exit"
    echo "  --skip-checks      Skip running local Python syntax validation"
    echo "  --force, --rebuild Bypass all caches and force a full rebuild and redeploy"
    echo "  -f                 Short alias for --force"
    echo "  --help, -h         Display this reference and exit"
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
    echo "  ./run.sh --apis-only             # Pick project [1-N] and enable GCP APIs"
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
data_dir = Path("data")
if data_dir.exists():
    files.extend(sorted(p for p in data_dir.rglob("*") if p.is_file()))

for path in files:
    if path.exists():
        hasher.update(str(path).encode("utf-8"))
        hasher.update(path.read_bytes())

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
    python3 -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$target_file" 2>/dev/null
}

# Executes a shell command quietly, shows its log output only if an error occurs,
# and lets the user interactively Retry (1), Skip (2), or Abort (3) on failure.
run_step() {
    local step_name="$1"
    local command="$2"

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
            2) return 0 ;;
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
# SECTION 4: Interactive GCP Project Selection
# ==============================================================================
CURRENT_GCLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)

if [ -n "$PROJECT_ID_OVERRIDE" ]; then
    PROJECT_ID="$PROJECT_ID_OVERRIDE"
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
            DEFAULT_NEW_PROJECT_ID="dash-gcp-$((RANDOM % 90000 + 10000))"
            read -p "👉 Enter a new Project ID (default: $DEFAULT_NEW_PROJECT_ID): " NEW_PROJECT_ID
            NEW_PROJECT_ID=$(echo "$NEW_PROJECT_ID" | xargs)
            PROJECT_ID="${NEW_PROJECT_ID:-$DEFAULT_NEW_PROJECT_ID}"

            read -p "👉 Enter a display name for the project (default: $PROJECT_ID): " NEW_PROJECT_NAME
            NEW_PROJECT_NAME=$(echo "$NEW_PROJECT_NAME" | xargs)
            PROJECT_NAME="${NEW_PROJECT_NAME:-$PROJECT_ID}"

            echo ""
            run_step "Create GCP Project '$PROJECT_ID'" "gcloud projects create \"$PROJECT_ID\" --name=\"$PROJECT_NAME\""

            # Check if an open billing account is available to link (required for Cloud Run & Cloud Build APIs)
            BILLING_ACCOUNTS=()
            BILLING_NAMES=()
            while IFS=$'\t' read -r bid bname; do
                if [ -n "$bid" ]; then
                    BILLING_ACCOUNTS+=("$bid")
                    BILLING_NAMES+=("$bname")
                fi
            done < <(gcloud billing accounts list --filter="open=true" --format="value(name.basename(),displayName)" 2>/dev/null)

            BILLING_COUNT=${#BILLING_ACCOUNTS[@]}
            if [ "$BILLING_COUNT" -eq 1 ]; then
                echo "💳 Found active billing account: ${BILLING_NAMES[0]} (${BILLING_ACCOUNTS[0]})"
                read -p "👉 Link this billing account to '$PROJECT_ID'? [Y/n]: " LINK_BILLING
                LINK_BILLING=$(echo "$LINK_BILLING" | xargs)
                if [[ -z "$LINK_BILLING" || "$LINK_BILLING" =~ ^[Yy] ]]; then
                    run_step "Link Billing Account to '$PROJECT_ID'" "gcloud billing projects link \"$PROJECT_ID\" --billing-account=\"${BILLING_ACCOUNTS[0]}\""
                fi
            elif [ "$BILLING_COUNT" -gt 1 ]; then
                echo ""
                echo "Available Billing Accounts:"
                echo "--------------------------------------------------"
                for (( i=0; i<BILLING_COUNT; i++ )); do
                    idx=$((i + 1))
                    printf "  %2d) %-24s (%s)\n" "$idx" "${BILLING_ACCOUNTS[$i]}" "${BILLING_NAMES[$i]}"
                done
                echo "--------------------------------------------------"
                read -p "👉 Select a billing account to link [1-$BILLING_COUNT] (or press Enter to skip): " BILLING_CHOICE
                BILLING_CHOICE=$(echo "$BILLING_CHOICE" | xargs)
                if [[ "$BILLING_CHOICE" =~ ^[0-9]+$ ]] && [ "$BILLING_CHOICE" -ge 1 ] && [ "$BILLING_CHOICE" -le "$BILLING_COUNT" ]; then
                    SELECTED_BILLING="${BILLING_ACCOUNTS[$((BILLING_CHOICE - 1))]}"
                    run_step "Link Billing Account to '$PROJECT_ID'" "gcloud billing projects link \"$PROJECT_ID\" --billing-account=\"$SELECTED_BILLING\""
                fi
            else
                echo "⚠️  Note: No active billing accounts detected via gcloud. Make sure billing is enabled for '$PROJECT_ID' in the GCP Console before enabling APIs."
                echo ""
            fi
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
        echo "--------------------------------------------------"
        read -p "👉 Select a project by number [1-$PROJECT_COUNT]: " PROJECT_CHOICE
        PROJECT_CHOICE=$(echo "$PROJECT_CHOICE" | xargs)

        if ! [[ "$PROJECT_CHOICE" =~ ^[0-9]+$ ]] || [ "$PROJECT_CHOICE" -lt 1 ] || [ "$PROJECT_CHOICE" -gt "$PROJECT_COUNT" ]; then
            echo "❌ Error: Invalid selection '$PROJECT_CHOICE'. Please enter a number between 1 and $PROJECT_COUNT."
            exit 1
        fi
        PROJECT_ID="${PROJECT_IDS[$((PROJECT_CHOICE - 1))]}"
    fi
fi

if [ -z "$PROJECT_ID" ]; then
    echo "❌ Error: No GCP Project ID selected."
    exit 1
fi

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

if [ -n "$LAST_DEPLOYED_PROJECT_ID" ] && [ "$PROJECT_ID" != "$LAST_DEPLOYED_PROJECT_ID" ]; then
    echo "ℹ️  Switched GCP Project ($PROJECT_ID vs previous $LAST_DEPLOYED_PROJECT_ID). Resetting setup cache."
    APIS_INITIALIZED="false"
    IAM_INITIALIZED="false"
    INFRA_INITIALIZED="false"
    LAST_SOURCE_HASH=""
    LAST_ENV_HASH=""
fi

# ==============================================================================
# SECTION 6: Google Cloud API Enablement (--apis-only or Full Deploy)
# ==============================================================================
enable_required_apis() {
    if [ "$FORCE_REBUILD" = false ] && [ "$APIS_INITIALIZED" = "true" ] && [ "$PROJECT_ID" = "$LAST_DEPLOYED_PROJECT_ID" ]; then
        echo "⚡ Google Cloud APIs already enabled for $PROJECT_ID (skipping; use --force to re-verify)."
    else
        run_step "Enable Google Cloud APIs" "gcloud services enable ${REQUIRED_APIS[*]} --project $PROJECT_ID"
        APIS_INITIALIZED="true"
        save_config_state
    fi
}

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

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

if [ "$FORCE_REBUILD" = false ] && [ "$IAM_INITIALIZED" = "true" ] && [ "$PROJECT_ID" = "$LAST_DEPLOYED_PROJECT_ID" ]; then
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
    IAM_INITIALIZED="true"
    save_config_state
fi

# ==============================================================================
# SECTION 9: Step 3A — Container Image Build (Artifact Registry & Cloud Build)
# ==============================================================================
echo "=== Step 3: Cloud Run Deployment ==="

if [ "$FORCE_REBUILD" = false ] && [ "$INFRA_INITIALIZED" = "true" ] && [ "$PROJECT_ID" = "$LAST_DEPLOYED_PROJECT_ID" ]; then
    echo "⚡ Artifact Registry repository ($REPO_NAME) already initialized."
else
    run_step "Create Artifact Registry Repository" "gcloud artifacts repositories create $REPO_NAME --repository-format=docker --location=$REGION --project=$PROJECT_ID || true"
    INFRA_INITIALIZED="true"
    save_config_state
fi

ENV_YAML_FILE="/tmp/dash_gcp_env.yaml"
cat <<EOF > "$ENV_YAML_FILE"
GCP_PROJECT: "$PROJECT_ID"
GOOGLE_CLOUD_PROJECT: "$PROJECT_ID"
EOF

CURRENT_SOURCE_HASH=$(get_source_sha256)
CURRENT_ENV_HASH=$(get_file_sha256 "$ENV_YAML_FILE")
IMAGE_TAG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${SERVICE_NAME}:latest"

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
