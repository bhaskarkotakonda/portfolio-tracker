#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE"
  echo "Create it from template:"
  echo "  cp .env.autopilot.example .env"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

missing=0

require() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "$value" || "$value" == "CHANGE_ME" || "$value" == "your-"* ]]; then
    echo "Missing required variable: $name"
    missing=1
  fi
}

echo "Running autopilot preflight with $ENV_FILE"

require APP_BASE_URL
require API_BASE_URL
require CLOUDFLARE_ACCOUNT_ID
require CLOUDFLARE_API_TOKEN
require D1_DATABASE_ID
require R2_RAW_BUCKET
require R2_BACKUP_BUCKET
require QUEUE_JOBS_NAME

if [[ "${ENABLE_TELEGRAM:-true}" == "true" ]]; then
  require TELEGRAM_BOT_TOKEN
  require TELEGRAM_WEBHOOK_SECRET
fi

if [[ "${USE_FREE_ONLY:-true}" == "false" ]]; then
  require POLYGON_API_KEY
  require ANTHROPIC_API_KEY
else
  echo "Free-only mode enabled: skipping paid API key requirements."
fi

if [[ $missing -eq 1 ]]; then
  echo
  echo "Preflight failed. Fill missing vars in $ENV_FILE and rerun."
  exit 1
fi

echo "Env variable checks passed."

if command -v wrangler >/dev/null 2>&1; then
  echo "wrangler found: $(wrangler --version)"
else
  echo "wrangler not found. Install with:"
  echo "  npm install -g wrangler"
  exit 1
fi

if command -v node >/dev/null 2>&1; then
  echo "node found: $(node --version)"
else
  echo "node not found. Install Node.js 20+."
  exit 1
fi

echo
echo "Autopilot preflight completed successfully."
echo "Next: run your scaffold/deploy workflow with this env loaded."
