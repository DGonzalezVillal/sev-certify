#!/bin/bash
set -euo pipefail

EFI_PATH="/usr/local/lib/guest-image/guest.efi"
MEASUREMENT_FILE="/usr/local/lib/guest-image/guest_measurement.txt"
GUEST_ERROR_LOG="/tmp/guest-error.log"
BOOT_LOG_DIR="/var/log/journal/guest-logs"

OVMF_PATH=""
for path in /usr/share/ovmf/OVMF.amdsev.fd /usr/share/edk2/ovmf/OVMF.amdsev.fd; do
  [[ -f "$path" ]] && { OVMF_PATH="$path"; break; }
done

if [[ -z "$OVMF_PATH" ]]; then
  echo "ERROR: AMDSEV compatible OVMF not found" >&2
  exit 1
fi

calculated_measurement_hex=$(awk -F "0x" '{print $2}' "${MEASUREMENT_FILE}")
guest_measurement_sha256sum=$(
  echo "${calculated_measurement_hex}" \
  | sha256sum | cut -d ' ' -f 1 \
  | xxd -r -p | base64
)

truncate -s 0 "$GUEST_ERROR_LOG"

qemu-system-x86_64 \
  -enable-kvm \
  -machine q35 \
  -cpu EPYC-v4 \
  -machine memory-encryption=sev0 \
  -monitor none \
  -display none \
  -object memory-backend-memfd,id=ram1,size=2048M \
  -machine memory-backend=ram1 \
  -object sev-snp-guest,id=sev0,cbitpos=51,reduced-phys-bits=1,kernel-hashes=on,host-data="${guest_measurement_sha256sum}" \
  -bios "${OVMF_PATH}" \
  -kernel "${EFI_PATH}" \
  2> "${GUEST_ERROR_LOG}" &


TIMEOUT=60
INTERVAL=1
ELAPSED=0

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    if journalctl -D "${BOOT_LOG_DIR}" 2>/dev/null | grep -q "boot-successful"; then
        echo "Guest boot successful."
        exit 0
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo -e "ERROR: Timed out waiting for SNP Guest to signal successful boot.\n" >&2

# Show guest boot log errors if any
if [ -s "${GUEST_ERROR_LOG}" ]; then
    echo -e "QEMU error log:\n" >&2
    cat "${GUEST_ERROR_LOG}" >&2
fi

exit 2
