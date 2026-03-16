#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT_DIR="$SCRIPT_DIR/experiment"
CONFIG_FILE="$SCRIPT_DIR/config.env"

# Load config file (provides defaults for all settings)
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=config.env
    source "$CONFIG_FILE"
else
    echo "Warning: config.env not found at $CONFIG_FILE; using built-in defaults."
fi

# Map config values to script variables (config -> script defaults)
MODE="${EXPERIMENT_MODE:-local}"
BUCKET="${S3_BUCKET:-}"
REGION="${AWS_REGION:-us-east-2}"
JOB_DEF="${BATCH_JOB_DEFINITION:-benchmark-job-definition:1}"
JOB_QUEUE="${BATCH_JOB_QUEUE:-benchmark-gpu-queue}"
VCPUS="${BATCH_VCPUS:-}"
MEMORY="${BATCH_MEMORY:-}"
GPUS="${BATCH_GPUS:-}"
ECR_REPO_URI="${ECR_REPO:-}"

# Parse CLI arguments (override config values)
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --mode) MODE="$2"; shift ;;
        --bucket) BUCKET="$2"; shift ;;
        --region) REGION="$2"; shift ;;
        --ecr-repo) ECR_REPO_URI="$2"; shift ;;
        --job-def) JOB_DEF="$2"; shift ;;
        --queue) JOB_QUEUE="$2"; shift ;;
        --vcpus) VCPUS="$2"; shift ;;
        --memory) MEMORY="$2"; shift ;;
        --gpus) GPUS="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ -z "$BUCKET" ] && [ "$MODE" == "batch" ]; then
    echo "Error: --bucket is required for batch mode."
    exit 1
fi

if [ -z "$ECR_REPO_URI" ] && [ "$MODE" == "batch" ]; then
    echo "Error: ECR_REPO must be set in config.env or passed via --ecr-repo for batch mode."
    exit 1
fi

# Generate a unique key for this run
RUN_KEY="run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
echo "=== Run Key: $RUN_KEY ==="

if [ "$MODE" == "local" ]; then
    echo "Starting local benchmark run..."

    COMPOSE_FILE="$EXPERIMENT_DIR/docker-compose.yaml"

    # Create a local results directory for this run
    RUN_DIR="$EXPERIMENT_DIR/results/$RUN_KEY"
    mkdir -p "$RUN_DIR"

    # Export environment variables for the container (via docker-compose)
    export S3_BUCKET="$BUCKET"
    export AWS_REGION="$REGION"
    export S3_PREFIX="${S3_PREFIX:-benchmark-results}"
    export RUN_KEY

    # Build and run the container
    echo "Building and running experiment via Docker Compose..."
    docker compose -f "$COMPOSE_FILE" up --build --abort-on-container-exit ${DOCKER_COMPOSE_EXTRA_FLAGS:-}
    echo "Container finished."

    # Copy results from the shared volume into the run directory
    CONTAINER_RESULTS="$EXPERIMENT_DIR/results/results.json"
    CONTAINER_HARDWARE="$EXPERIMENT_DIR/results/hardware.json"
    if [[ -f "$CONTAINER_RESULTS" ]]; then
        mv "$CONTAINER_RESULTS" "$RUN_DIR/results.json"
    fi
    if [[ -f "$CONTAINER_HARDWARE" ]]; then
        mv "$CONTAINER_HARDWARE" "$RUN_DIR/hardware.json"
    fi

    # Print results
    if [[ -f "$RUN_DIR/results.json" ]]; then
        echo "Results:"
        cat "$RUN_DIR/results.json"
    else
        echo "Warning: results.json not found in $RUN_DIR"
    fi

elif [ "$MODE" == "batch" ]; then
    echo "Starting batch benchmark run..."

    # --- Build and push Docker image to ECR ---
    IMAGE_TAG="$RUN_KEY"
    IMAGE_URI="$ECR_REPO_URI:$IMAGE_TAG"

    echo "Authenticating with ECR..."
    # Extract the ECR registry (everything before the first /)
    ECR_REGISTRY="${ECR_REPO_URI%%/*}"
    aws ecr get-login-password --region "$REGION" \
        | docker login --username AWS --password-stdin "$ECR_REGISTRY"

    echo "Building Docker image: $IMAGE_URI"
    # Ensure we build for linux/amd64 since AWS Batch compute environments are typically x86_64
    docker build --platform linux/amd64 -t "$IMAGE_URI" "$EXPERIMENT_DIR"

    echo "Pushing image to ECR..."
    docker push "$IMAGE_URI"
    echo "Image pushed successfully."

    echo "Submitting benchmark job to AWS Batch..."

    # Register a new job definition revision with the pushed image
    echo "Registering new job definition revision with image: $IMAGE_URI"
    TEMP_DEF=$(mktemp)
    TEMP_REG=$(mktemp)
    aws batch describe-job-definitions \
        --job-definition-name "${JOB_DEF%%:*}" \
        --status ACTIVE \
        --region "$REGION" \
        --query 'jobDefinitions | sort_by(@, &revision) | [-1]' \
        --output json > "$TEMP_DEF"

    # Update image and extract only the fields needed for registration
    jq --arg IMAGE "$IMAGE_URI" '
        .containerProperties.image = $IMAGE
        | {
            jobDefinitionName: .jobDefinitionName,
            type: .type,
            containerProperties: .containerProperties
          }
        | if .retryStrategy then . + {retryStrategy: .retryStrategy} else . end
        | if .timeout then . + {timeout: .timeout} else . end
        | if .platformCapabilities then . + {platformCapabilities: .platformCapabilities} else . end
    ' "$TEMP_DEF" > "$TEMP_REG"

    NEW_JOB_DEF_ARN=$(aws batch register-job-definition \
        --region "$REGION" \
        --cli-input-json "file://$TEMP_REG" \
        --query 'jobDefinitionArn' \
        --output text)
    rm -f "$TEMP_DEF" "$TEMP_REG"

    echo "Registered new job definition: $NEW_JOB_DEF_ARN"

    # Build resource requirements array for container overrides
    RESOURCE_REQS=""
    if [[ -n "$VCPUS" ]]; then
        RESOURCE_REQS+="{\"type\": \"VCPU\", \"value\": \"$VCPUS\"},"
    fi
    if [[ -n "$MEMORY" ]]; then
        RESOURCE_REQS+="{\"type\": \"MEMORY\", \"value\": \"$MEMORY\"},"
    fi
    if [[ -n "$GPUS" ]]; then
        RESOURCE_REQS+="{\"type\": \"GPU\", \"value\": \"$GPUS\"},"
    fi
    # Remove trailing comma
    RESOURCE_REQS="${RESOURCE_REQS%,}"

    # Build container overrides JSON
    CONTAINER_OVERRIDES="{
        \"environment\": [
            {\"name\": \"RUN_MODE\", \"value\": \"batch\"},
            {\"name\": \"S3_BUCKET\", \"value\": \"$BUCKET\"},
            {\"name\": \"S3_PREFIX\", \"value\": \"${S3_PREFIX:-benchmark-results}\"},
            {\"name\": \"AWS_REGION\", \"value\": \"$REGION\"},
            {\"name\": \"RUN_KEY\", \"value\": \"$RUN_KEY\"}
        ]"
    if [[ -n "$RESOURCE_REQS" ]]; then
        CONTAINER_OVERRIDES+=",
        \"resourceRequirements\": [$RESOURCE_REQS]"
    fi
    CONTAINER_OVERRIDES+="}"

    # Submit job
    aws batch submit-job \
        --job-name "benchmark-run-$(date +%s)" \
        --job-queue "$JOB_QUEUE" \
        --job-definition "$NEW_JOB_DEF_ARN" \
        --region "$REGION" \
        --container-overrides "$CONTAINER_OVERRIDES"
    
    echo "Job submitted successfully to $JOB_QUEUE."
    if [[ -n "$VCPUS" || -n "$MEMORY" || -n "$GPUS" ]]; then
        echo "Resource overrides: vCPUs=${VCPUS:-default} memory=${MEMORY:-default}MiB GPUs=${GPUS:-none}"
    fi
else
    echo "Invalid mode. Use '--mode local' or '--mode batch'."
    exit 1
fi
