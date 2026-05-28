#!/usr/bin/env bash
#
# iq_cam_sweep.sh — Sweep IQ entry count through CACTI's CAM model and collect
#                   energy/timing results for the wakeup tag array.
#
# Models the wakeup (tag-CAM) half of the regular CAM-based IQ. Pair with
# iq_cam_payload_sweep.sh (the payload SRAM half) and sum the two to get the
# regular IQ's total energy. Compare against diq_sram_sweep.sh (the DIQ).
#
# Usage:
#   ./iq_cam_sweep.sh [tag_width_bytes] [rw_ports] [search_ports] [tech_nm]
#
# Defaults (MagnaOpus / gem5 non-super calibration; see sic_parvis.py:127-160):
#   tag_width_bytes = 4   (3 src PRF tags × 10 bits = 30 bits → 4 B; 794 phys
#                          regs total = 280 int + 224 fp + 256 vec + 32 vp + 2
#                          mat. int/fp from sic_parvis.py:144-145; vec/vp/mat
#                          inherited from BaseO3CPU defaults)
#   rw_ports        = 8   (dispatchWidth = 8, inherited from BaseO3CPU)
#   search_ports    = 8   (wbWidth = 8, sic_parvis.py:134 — one broadcast bus
#                          per writeback lane)
#   tech_nm         = 22  (CACTI floor; Ice Lake is Intel 10 nm)
#
# Output:
#   iq_cam_sweep_results.csv  — machine-readable CSV
#   Printed table             — human-readable summary to stdout
#
# Sweep points (entries): 8 12 16 24 32 48 64 96 128 160

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACTI="${SCRIPT_DIR}/cacti"
BASE_CFG="${SCRIPT_DIR}/sample_config_files/iq_cam.cfg"
RESULTS_CSV="${SCRIPT_DIR}/iq_cam_sweep_results.csv"
TMP_CFG=$(mktemp /tmp/iq_cam_cacti_XXXXXX.cfg)

TAG_WIDTH_BYTES=${1:-4}
RW_PORTS=${2:-8}
SEARCH_PORTS=${3:-8}
TECH_NM=${4:-22}
TECH_UM=$(echo "scale=3; ${TECH_NM}/1000" | bc)
BUS_WIDTH_BITS=$(( TAG_WIDTH_BYTES * 8 ))

ENTRIES_LIST=(8 12 16 24 32 48 64 96 128 160)

if [[ ! -x "${CACTI}" ]]; then
    echo "ERROR: cacti binary not found at ${CACTI}" >&2
    exit 1
fi

cleanup() { rm -f "${TMP_CFG}"; }
trap cleanup EXIT

# Write CSV header
echo "entries,size_bytes,tag_width_bytes,rw_ports,search_ports,tech_nm,access_time_ns,search_delay_ns,cycle_time_ns,read_energy_nJ,write_energy_nJ,search_energy_nJ,leakage_mW,area_mm2" \
    > "${RESULTS_CSV}"

# Print table header
printf "\n%-8s %-10s %-12s %-12s %-12s %-12s %-12s %-12s %-10s\n" \
    "Entries" "Size(B)" "Search(nJ)" "Read(nJ)" "Write(nJ)" "Leak(mW)" "Search(ns)" "Access(ns)" "Area(mm2)"
printf -- "%-8s %-10s %-12s %-12s %-12s %-12s %-12s %-12s %-10s\n" \
    "-------" "-------" "----------" "--------" "---------" "--------" "----------" "----------" "--------"

for ENTRIES in "${ENTRIES_LIST[@]}"; do
    SIZE_BYTES=$(( ENTRIES * TAG_WIDTH_BYTES ))

    # Build config by substituting key parameters into the base config
    sed \
        -e "s|^-size (bytes).*|-size (bytes) ${SIZE_BYTES}|" \
        -e "s|^-block size (bytes).*|-block size (bytes) ${TAG_WIDTH_BYTES}|" \
        -e "s|^-read-write port.*|-read-write port ${RW_PORTS}|" \
        -e "s|^-search port.*|-search port ${SEARCH_PORTS}|" \
        -e "s|^-output/input bus width.*|-output/input bus width ${BUS_WIDTH_BITS}|" \
        -e "s|^-technology (u).*|-technology (u) ${TECH_UM}|" \
        "${BASE_CFG}" > "${TMP_CFG}"

    # Run CACTI; suppress stderr (wire/tech warnings).
    # CACTI exits 0 on internal errors like "Cache size must >=64", so detect those.
    OUTPUT=$(${CACTI} -infile "${TMP_CFG}" 2>/dev/null) || true
    if echo "${OUTPUT}" | grep -qiE "cache size must|invalid|error" || \
       ! echo "${OUTPUT}" | grep -q "Access time"; then
        printf "%-8s %-10s  FAILED (size < 64 B, or too many ports for this array)\n" \
            "${ENTRIES}" "${SIZE_BYTES}"
        continue
    fi

    # Parse CAM-specific fields from the DETAILED output block.
    # Note: "energy/access  (nJ)" has two spaces before (nJ) in the source.
    ACCESS=$(   echo "${OUTPUT}" | awk '/Access time \(ns\)/{print $NF; exit}')
    CYCLE=$(    echo "${OUTPUT}" | awk '/Cycle time \(ns\)/{print $NF; exit}')
    SEARCH_D=$( echo "${OUTPUT}" | awk '/CAM search delay \(ns\)/{print $NF; exit}')
    SEARCH_E=$( echo "${OUTPUT}" | awk '/Total dynamic associative search energy/{print $NF; exit}')
    READ=$(     echo "${OUTPUT}" | awk '/Total dynamic read energy per access \(nJ\)/{print $NF; exit}')
    WRITE=$(    echo "${OUTPUT}" | awk '/Total dynamic write energy per access \(nJ\)/{print $NF; exit}')
    LEAK=$(     echo "${OUTPUT}" | awk '/Total leakage power of a bank \(mW\)/{print $NF; exit}')
    AREA=$(     echo "${OUTPUT}" | awk '/CAM array: Area \(mm2\)/{print $NF; exit}')

    # Append to CSV
    echo "${ENTRIES},${SIZE_BYTES},${TAG_WIDTH_BYTES},${RW_PORTS},${SEARCH_PORTS},${TECH_NM},${ACCESS},${SEARCH_D},${CYCLE},${READ},${WRITE},${SEARCH_E},${LEAK},${AREA}" \
        >> "${RESULTS_CSV}"

    # Print table row
    printf "%-8s %-10s %-12s %-12s %-12s %-12s %-12s %-12s %-10s\n" \
        "${ENTRIES}" "${SIZE_BYTES}" "${SEARCH_E}" "${READ}" "${WRITE}" "${LEAK}" "${SEARCH_D}" "${ACCESS}" "${AREA}"
done

printf "\nConfig: tag_width=%d B  rw_ports=%d  search_ports=%d  tech=%d nm\n" \
    "${TAG_WIDTH_BYTES}" "${RW_PORTS}" "${SEARCH_PORTS}" "${TECH_NM}"
printf "Results written to: %s\n\n" "${RESULTS_CSV}"
