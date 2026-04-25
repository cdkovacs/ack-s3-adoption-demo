#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

banner() { echo; echo "=========================================="; echo "  $*"; echo "=========================================="; }

if [[ "${1:-}" == "--reset" ]]; then
  banner "RESET — running teardown first"
  "$SCRIPT_DIR/scripts/99-teardown.sh" || true
fi

banner "00 install ack controller"
"$SCRIPT_DIR/scripts/00-install-ack.sh"

banner "10 terraform create + seed"
"$SCRIPT_DIR/scripts/10-tf-create.sh"

banner "20 terraform state rm"
"$SCRIPT_DIR/scripts/20-tf-state-rm.sh"

banner "30 ack adopt"
"$SCRIPT_DIR/scripts/30-adopt.sh"

banner "40 validate"
"$SCRIPT_DIR/scripts/40-validate.sh"

banner "DEMO COMPLETE"
echo "Run $SCRIPT_DIR/scripts/99-teardown.sh to clean up."
