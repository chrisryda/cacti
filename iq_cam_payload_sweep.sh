#!/usr/bin/env bash
#
# iq_cam_payload_sweep.sh — Sweep the payload-SRAM half of the regular CAM-based IQ.
#
# The regular CAM IQ has two parts:
#   - iq_cam.cfg           — narrow tag CAM (associative wakeup search)
#   - iq_cam_payload.cfg   — wide payload SRAM (indexed read at issue)
# Run iq_cam_sweep.sh AND this script, then sum CAM_energy + payload_energy
# to get the total regular-IQ energy. Compare against diq_sram_sweep.sh (the DIQ).
#
# Usage:
#   ./iq_cam_payload_sweep.sh [payload_width_bytes] [num_ports] [tech_nm]
#
# Defaults (gem5 non-super calibration; see iq_cam_payload.cfg header for
# the bit-level field table):
#   payload_width_bytes = 11  (82 bits: 3 src-ready + 10 dest tag + 7 OpClass
#                              + 5 FU port + 8 ROB ptr + 5 LSQ ptr + 32 imm
#                              + 3 status + 9 DIQ-consumer back-ptr → 11 B)
#   num_ports           = 8   (gem5 dispatch/issue/wb width = 8,
#                              BaseO3CPU.py:122-124)
#   tech_nm             = 22  (CACTI floor; Ice Lake is Intel 10 nm)
#
# Output:
#   iq_cam_payload_sweep_results.csv  — machine-readable CSV
#   Printed table                     — human-readable summary to stdout
#
# Sweep points (entries): 8 12 16 24 32 48 64 96 128 160

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACTI="${SCRIPT_DIR}/cacti"
BASE_CFG="${SCRIPT_DIR}/sample_config_files/iq_cam_payload.cfg"
RESULTS_CSV="${SCRIPT_DIR}/iq_cam_payload_sweep_results.csv"
TMP_CFG=$(mktemp /tmp/iq_cam_payload_cacti_XXXXXX.cfg)

PAYLOAD_WIDTH_BYTES=${1:-11}
NUM_PORTS=${2:-8}
TECH_NM=${3:-22}
TECH_UM=$(echo "scale=3; ${TECH_NM}/1000" | bc)
BUS_WIDTH_BITS=$(( PAYLOAD_WIDTH_BYTES * 8 ))

ENTRIES_LIST=(8 12 16 24 32 48 64 96 128 160)

if [[ ! -x "${CACTI}" ]]; then
    echo "ERROR: cacti binary not found at ${CACTI}" >&2
    exit 1
fi

cleanup() { rm -f "${TMP_CFG}"; }
trap cleanup EXIT

# Write CSV header
echo "entries,size_bytes,payload_width_bytes,ports,tech_nm,access_time_ns,cycle_time_ns,read_energy_nJ,write_energy_nJ,leakage_mW,area_mm2" \
    > "${RESULTS_CSV}"

# Print table header
printf "\n%-10s %-12s %-14s %-14s %-14s %-14s %-14s %-10s\n" \
    "Entries" "Size(B)" "Read(nJ)" "Write(nJ)" "Leakage(mW)" "Access(ns)" "Cycle(ns)" "Area(mm2)"
printf -- "%-10s %-12s %-14s %-14s %-14s %-14s %-14s %-10s\n" \
    "-------" "-------" "--------" "---------" "-----------" "----------" "---------" "--------"

for ENTRIES in "${ENTRIES_LIST[@]}"; do
    SIZE_BYTES=$(( ENTRIES * PAYLOAD_WIDTH_BYTES ))

    # Build config by substituting key parameters into the base config
    sed \
        -e "s|^-size (bytes).*|-size (bytes) ${SIZE_BYTES}|" \
        -e "s|^-block size (bytes).*|-block size (bytes) ${PAYLOAD_WIDTH_BYTES}|" \
        -e "s|^-read-write port.*|-read-write port ${NUM_PORTS}|" \
        -e "s|^-output/input bus width.*|-output/input bus width ${BUS_WIDTH_BITS}|" \
        -e "s|^-technology (u).*|-technology (u) ${TECH_UM}|" \
        "${BASE_CFG}" > "${TMP_CFG}"

    # Run CACTI; suppress stderr (wire/tech warnings).
    # CACTI exits 0 on internal errors like "Cache size must >=64", so detect those.
    OUTPUT=$(${CACTI} -infile "${TMP_CFG}" 2>/dev/null) || true
    if echo "${OUTPUT}" | grep -qiE "cache size must|invalid|error" || \
       ! echo "${OUTPUT}" | grep -q "Access time"; then
        printf "%-10s %-12s  FAILED (size < 64 B, or too many ports for this array)\n" \
            "${ENTRIES}" "${SIZE_BYTES}"
        continue
    fi

    # Parse fields from the DETAILED output block
    ACCESS=$(echo "${OUTPUT}" | awk '/Access time \(ns\)/{print $NF; exit}')
    CYCLE=$( echo "${OUTPUT}" | awk '/Cycle time \(ns\)/{print $NF; exit}')
    READ=$(  echo "${OUTPUT}" | awk '/Total dynamic read energy per access \(nJ\)/{print $NF; exit}')
    WRITE=$( echo "${OUTPUT}" | awk '/Total dynamic write energy per access \(nJ\)/{print $NF; exit}')
    LEAK=$(  echo "${OUTPUT}" | awk '/Total leakage power of a bank \(mW\)/{print $NF; exit}')
    AREA=$(  echo "${OUTPUT}" | awk '/Data array: Area \(mm2\)/{print $NF; exit}')

    # Append to CSV
    echo "${ENTRIES},${SIZE_BYTES},${PAYLOAD_WIDTH_BYTES},${NUM_PORTS},${TECH_NM},${ACCESS},${CYCLE},${READ},${WRITE},${LEAK},${AREA}" \
        >> "${RESULTS_CSV}"

    # Print table row
    printf "%-10s %-12s %-14s %-14s %-14s %-14s %-14s %-10s\n" \
        "${ENTRIES}" "${SIZE_BYTES}" "${READ}" "${WRITE}" "${LEAK}" "${ACCESS}" "${CYCLE}" "${AREA}"
done

printf "\nConfig: payload_width=%d B  ports=%d  tech=%d nm\n" \
    "${PAYLOAD_WIDTH_BYTES}" "${NUM_PORTS}" "${TECH_NM}"
printf "Results written to: %s\n\n" "${RESULTS_CSV}"
