#!/bin/bash
# Start a previously provisioned VM. Idempotent (systemd start on a running
# unit is a no-op).
#
# Inputs:
#   VIRTUAL_MACHINE_NAME

set -euo pipefail

: "${VIRTUAL_MACHINE_NAME:?required}"

systemctl start "firecracker-vm@${VIRTUAL_MACHINE_NAME}.service"
systemctl is-active "firecracker-vm@${VIRTUAL_MACHINE_NAME}.service"
