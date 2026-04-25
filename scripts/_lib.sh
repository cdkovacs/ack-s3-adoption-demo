# Common helpers, sourced by every phase script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$DEMO_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$DEMO_DIR/.env"
  set +a
else
  echo "!! $DEMO_DIR/.env not found — copy .env.example and fill it in" >&2
  exit 1
fi

NAMESPACE="ack-system"
SECRET_NAME="ack-s3-user-creds"
BUCKET_NAME_FILE="$DEMO_DIR/.run-bucket-name"
ETAGS_FILE="$DEMO_DIR/.run-etags.json"

require_env() {
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      echo "!! $var is not set in $DEMO_DIR/.env" >&2
      exit 1
    fi
  done
}
