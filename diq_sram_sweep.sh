#!/usr/bin/env bash
#
# diq_sram_sweep.sh — Sweep DIQ entry count through CACTI's SRAM model.
#
# The DIQ is a SECONDARY side queue running alongside the regular CAM IQ
# (iq_cam.cfg + iq_cam_payload.cfg). It holds delta-candidate instructions
# and uses indexed wakeup — no associative search.
#
# This script sweeps DIQ entry count in isolation. To sweep (IQ, DIQ) design
# points and sum the whole-system energy, use design_point_sweep.sh.
#
# Usage:
#   ./diq_sram_sweep.sh [entry_width_bytes] [num_ports] [tech_nm]
#
# Defaults (MagnaOpus / gem5 non-super calibration; see sic_parvis.py:127-160
# and diq_sram.cfg header for full bit-level field table):
#   entry_width_bytes = 12  (91 bits: 30 src tags + 3 src-ready + 10 dest
#                            + 7 OpClass + 5 FU port + 9 ROB ptr (352 ROB)
#                            + 7 LSQ ptr (LQ=128/SQ=72) + 17 imm (16+sign)
#                            + 3 status → 12 B. Source PRF tags live in the
#                            entry — read at issue to drive PRF — but as
#                            plain SRAM cells, not CAM cells. The DIQ holds
#                            memory ops, so LSQ pointer is included.)
#   num_ports         = 4   (side queue: ~2 dispatch writes + ~2 issue reads
#                            per cycle; pipeline-width port counts (8+) inflate
#                            peripheral leakage/area)
#   tech_nm           = 22  (CACTI floor; Ice Lake is Intel 10 nm — scale analytically)
#
# Note: this script sweeps the DIQ array in isolation. For total-system
# energy at a given (IQ, DIQ) design point, use design_point_sweep.sh —
# which also adds a diq_wakeup_e_nJ column approximating single-bit ready
# flips as 1/N of a full row write.
#
# Output:
#   diq_sram_sweep_results.csv   — machine-readable CSV
#   Printed table                — human-readable summary to stdout
#
# Sweep points (entries): 8 12 16 24 32 48 64 96 128 160

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACTI="${SCRIPT_DIR}/cacti"
BASE_CFG="${SCRIPT_DIR}/sample_config_files/diq_sram.cfg"
RESULTS_CSV="${SCRIPT_DIR}/diq_sram_sweep_results.csv"
TMP_CFG=$(mktemp /tmp/iq_cacti_XXXXXX.cfg)

ENTRY_WIDTH_BYTES=${1:-12}
NUM_PORTS=${2:-4}
TECH_NM=${3:-22}
TECH_UM=$(echo "scale=3; ${TECH_NM}/1000" | bc)
BUS_WIDTH_BITS=$(( ENTRY_WIDTH_BYTES * 8 ))

ENTRIES_LIST=(8 12 16 24 32 48 64 96 128 160)

if [[ ! -x "${CACTI}" ]]; then
    echo "ERROR: cacti binary not found at ${CACTI}" >&2
    exit 1
fi

cleanup() { rm -f "${TMP_CFG}"; }
trap cleanup EXIT

# Write CSV header
echo "entries,size_bytes,entry_width_bytes,ports,tech_nm,access_time_ns,cycle_time_ns,read_energy_nJ,write_energy_nJ,leakage_mW,area_mm2" \
    > "${RESULTS_CSV}"

# Print table header
printf "\n%-10s %-12s %-14s %-14s %-14s %-14s %-14s %-10s\n" \
    "Entries" "Size(B)" "Read(nJ)" "Write(nJ)" "Leakage(mW)" "Access(ns)" "Cycle(ns)" "Area(mm2)"
printf -- "%-10s %-12s %-14s %-14s %-14s %-14s %-14s %-10s\n" \
    "-------" "-------" "--------" "---------" "-----------" "----------" "---------" "--------"

for ENTRIES in "${ENTRIES_LIST[@]}"; do
    SIZE_BYTES=$(( ENTRIES * ENTRY_WIDTH_BYTES ))

    # Build config by substituting key parameters into the base config
    sed \
        -e "s|^-size (bytes).*|-size (bytes) ${SIZE_BYTES}|" \
        -e "s|^-block size (bytes).*|-block size (bytes) ${ENTRY_WIDTH_BYTES}|" \
        -e "s|^-read-write port.*|-read-write port ${NUM_PORTS}|" \
        -e "s|^-output/input bus width.*|-output/input bus width ${BUS_WIDTH_BITS}|" \
        -e "s|^-technology (u).*|-technology (u) ${TECH_UM}|" \
        "${BASE_CFG}" > "${TMP_CFG}"

    # Run CACTI; suppress stderr (wire/tech warnings).
    # Small arrays with many ports can fail: CACTI requires enough rows/columns
    # to place all port sense amps. Reduce NUM_PORTS or increase ENTRY_WIDTH_BYTES
    # if entries below ~32 are needed.
    OUTPUT=$(${CACTI} -infile "${TMP_CFG}" 2>/dev/null) || {
        printf "%-10s %-12s  FAILED (array too small for %d ports)\n" \
            "${ENTRIES}" "${SIZE_BYTES}" "${NUM_PORTS}"
        continue
    }

    # Parse fields from the DETAILED output block
    ACCESS=$(echo "${OUTPUT}" | awk '/Access time \(ns\)/{print $NF; exit}')
    CYCLE=$( echo "${OUTPUT}" | awk '/Cycle time \(ns\)/{print $NF; exit}')
    READ=$(  echo "${OUTPUT}" | awk '/Total dynamic read energy per access \(nJ\)/{print $NF; exit}')
    WRITE=$( echo "${OUTPUT}" | awk '/Total dynamic write energy per access \(nJ\)/{print $NF; exit}')
    LEAK=$(  echo "${OUTPUT}" | awk '/Total leakage power of a bank \(mW\)/{print $NF; exit}')
    AREA=$(  echo "${OUTPUT}" | awk '/Data array: Area \(mm2\)/{print $NF; exit}')

    # Append to CSV
    echo "${ENTRIES},${SIZE_BYTES},${ENTRY_WIDTH_BYTES},${NUM_PORTS},${TECH_NM},${ACCESS},${CYCLE},${READ},${WRITE},${LEAK},${AREA}" \
        >> "${RESULTS_CSV}"

    # Print table row
    printf "%-10s %-12s %-14s %-14s %-14s %-14s %-14s %-10s\n" \
        "${ENTRIES}" "${SIZE_BYTES}" "${READ}" "${WRITE}" "${LEAK}" "${ACCESS}" "${CYCLE}" "${AREA}"
done

printf "\nConfig: entry_width=%d B  ports=%d  tech=%d nm\n" \
    "${ENTRY_WIDTH_BYTES}" "${NUM_PORTS}" "${TECH_NM}"
printf "Results written to: %s\n\n" "${RESULTS_CSV}"
