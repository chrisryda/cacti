#!/usr/bin/env bash
#
# design_point_sweep.sh — Run CACTI on each (IQ, DIQ) design point.
#
# For each pair (IQ, DIQ) in the CONFIGS list, runs CACTI three times:
#   1. iq_cam.cfg          at IQ entries  → wakeup-CAM cost
#   2. iq_cam_payload.cfg  at IQ entries  → payload-SRAM cost
#   3. diq_sram.cfg        at DIQ entries → indexed-SRAM cost
#
# Sums energy/leakage/area and emits one row per design point to
# design_point_results.csv.
#
# Default sweep grid: 54 design points, matching the gem5 diq.sweep.sh
# CONFIGS array. Budgets ∈ {8, 16, 32, 64, 96, 128, 160}; each budget has a
# dense IQ/DIQ split list (e.g. budget=160 has 16 splits from 160-0 to
# 10-150 in steps of 10). See the CONFIGS array below for the full list.
#
# Some small-IQ points fall below CACTI's 64 B CAM floor (IQ ≤ 16 entries
# at 4 B/entry = ≤64 B) and are emitted as PARTIAL rows (still appear in
# the CSV with empty fields for the CAM half).
#
# Usage:
#   ./design_point_sweep.sh [options] [iq_entry_bytes [diq_entry_bytes [tech_nm]]]
#
# Options:
#   --pairs "X-Y X-Y ..."  Run only these IQ-DIQ pairs instead of the default
#                           gem5 grid. Each pair is `IQ-DIQ` (e.g. "160-0 90-70").
#   --pairs-file PATH       Read pairs from PATH (one per line, or
#                           whitespace-separated). Lines starting with `#`
#                           are ignored.
#   -h | --help             Print this header and exit.
#
# Positional args (legacy; still supported for backward compatibility):
#   1: iq_entry_bytes  (default 13)
#   2: diq_entry_bytes (default 12)
#   3: tech_nm         (default 22)
#
# Defaults (MagnaOpus / gem5 non-super calibration; see sic_parvis.py:127-160
# and modeling-plan.md for the bit-level field tables behind these widths):
#   iq_entry_bytes  = 13   (4 B tag CAM + 9 B payload SRAM. Tag CAM holds
#                           3 src PRF tags × 10 bits = 30 b → 4 B. Payload
#                           holds the rest: dest tag + opcode + FU port +
#                           9 b ROB ptr (352 ROB) + 7 b LSQ ptr (LQ=128 /
#                           SQ=72) + 17 b immediate (16+sign) + status +
#                           DIQ-consumer back-ptr = 70 b → 9 B.)
#   diq_entry_bytes = 12   (91 b: 3 src tags + ready bits + dest + opcode
#                           + FU port + 9 b ROB ptr + 7 b LSQ ptr + 17 b
#                           immediate (16+sign) + status. Same logical
#                           fields as IQ entry minus the producer-side DIQ
#                           back-pointer, stored in plain SRAM cells. DIQ
#                           holds memory ops, so the LSQ ptr is included.)
#   tech_nm         = 22   (CACTI floor; Ice Lake is Intel 10 nm)
#
# Port counts (MagnaOpus, sic_parvis.py:133-135 + BaseO3CPU defaults):
#   IQ tag CAM:  8 RW (dispatch) + 8 search (writeback broadcast buses)
#   IQ payload: 8 RW (issue + dispatch + WB share these)
#   DIQ:        4 RW (side-queue traffic, NOT pipeline-width)
#
# Wakeup energy (single ready-bit flip in the DIQ on producer completion) is
# NOT modeled here. A previous version emitted a diq_wakeup_e_nJ column as
# diq_write_e / (entry_bits) but it has been dropped from the combiner —
# see modeling-plan.md "DIQ indexed-wakeup energy (not included)".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACTI="${SCRIPT_DIR}/cacti"
CFG_DIR="${SCRIPT_DIR}/sample_config_files"
RESULTS_CSV="${SCRIPT_DIR}/design_point_results.csv"

usage() { sed -n '2,/^$/p' "$0"; }

IQ_ENTRY_BYTES=13
DIQ_ENTRY_BYTES=12
TECH_NM=22
PAIRS_OVERRIDE=""

# Parse args: flags consumed by name, positional args collected separately.
POS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pairs)      PAIRS_OVERRIDE="${PAIRS_OVERRIDE} $2"; shift 2;;
        --pairs-file)
            [[ -r "$2" ]] || { echo "ERROR: cannot read --pairs-file $2" >&2; exit 1; }
            PAIRS_OVERRIDE="${PAIRS_OVERRIDE} $(grep -vE '^[[:space:]]*#' "$2" | tr '\n' ' ')"
            shift 2;;
        -h|--help)    usage; exit 0;;
        --*)          echo "ERROR: unknown flag: $1" >&2; exit 1;;
        *)            POS+=("$1"); shift;;
    esac
done
[[ ${#POS[@]} -ge 1 ]] && IQ_ENTRY_BYTES="${POS[0]}"
[[ ${#POS[@]} -ge 2 ]] && DIQ_ENTRY_BYTES="${POS[1]}"
[[ ${#POS[@]} -ge 3 ]] && TECH_NM="${POS[2]}"
TECH_UM=$(echo "scale=3; ${TECH_NM}/1000" | bc)

# Architectural constants matching iq_cam.cfg / iq_cam_payload.cfg defaults.
# Tag CAM width: 3 src PRF tags × 10 bits → 30 bits → 4 B (MagnaOpus 794 phys regs)
IQ_TAG_BYTES=4
# Payload width: full entry minus tag bits
IQ_PAYLOAD_BYTES=$(( IQ_ENTRY_BYTES - IQ_TAG_BYTES ))
# Port assumptions (MagnaOpus / gem5 non-super: dispatch=8 inherited, issue/wb=8)
IQ_RW_PORTS=8         # dispatch writes
IQ_SEARCH_PORTS=8     # result-broadcast buses (one per WB lane)
IQ_PAYLOAD_PORTS=8    # issue read + dispatch write + WB update share these
DIQ_PORTS=4           # side queue: ~2 dispatch + ~2 issue per cycle (wakeup is a single-bit flip, not modeled here)

# Default design-point grid — mirrors the gem5 diq.sweep.sh CONFIGS array.
# Override with --pairs or --pairs-file.
if [[ -n "${PAIRS_OVERRIDE// }" ]]; then
    read -ra CONFIGS <<< "${PAIRS_OVERRIDE}"
else
    CONFIGS=(
        # budget=8 (1 config): IQ+DIQ=8 per curve
        8-0
        # budget=16 (2 configs)
        16-0   8-8
        # budget=32 (4 configs; 16-16 is symmetric midpoint)
        32-0   22-10  16-16  12-20
        # budget=64 (7 configs; 32-32 is symmetric midpoint)
        64-0   54-10  44-20  34-30  32-32  24-40  14-50
        # budget=96 (10 configs; 48-48 is symmetric midpoint)
        96-0   86-10  76-20  66-30  56-40  48-48  46-50  36-60  26-70  16-80
        # budget=128 (14 configs; 64-64 is symmetric midpoint)
        128-0  118-10 108-20 98-30  88-40  78-50  68-60  64-64  58-70  48-80  38-90  28-100 18-110 8-120
        # budget=160 (16 configs; 80-80 lands on regular grid)
        160-0  150-10 140-20 130-30 120-40 110-50 100-60 90-70  80-80  70-90  60-100 50-110 40-120 30-130 20-140 10-150
    )
fi

if [[ ! -x "${CACTI}" ]]; then
    echo "ERROR: cacti binary not found at ${CACTI}" >&2
    exit 1
fi

TMP_IQCAM=$(mktemp /tmp/dp_iqcam_XXXXXX.cfg)
TMP_IQPAY=$(mktemp /tmp/dp_iqpay_XXXXXX.cfg)
TMP_DIQ=$(mktemp   /tmp/dp_diq_XXXXXX.cfg)
cleanup() { rm -f "${TMP_IQCAM}" "${TMP_IQPAY}" "${TMP_DIQ}"; }
trap cleanup EXIT

# Run CACTI on a config; sets globals OUTPUT and STATUS ("OK" or "FAIL").
# Inline rather than a function-call so OUTPUT propagates (no subshell).
run_cacti_inline() { :; }   # placeholder — actual logic is inlined below

# Parse output (set globally to avoid subshell var-loss)
parse_iq_cam() {
    IQCAM_SEARCH_E=$(echo "${OUTPUT}" | awk '/Total dynamic associative search energy/{print $NF; exit}')
    IQCAM_LEAK=$(    echo "${OUTPUT}" | awk '/Total leakage power of a bank \(mW\)/{print $NF; exit}')
    IQCAM_AREA=$(    echo "${OUTPUT}" | awk '/CAM array: Area \(mm2\)/{print $NF; exit}')
}
parse_sram() {
    SRAM_READ_E=$(  echo "${OUTPUT}" | awk '/Total dynamic read energy per access \(nJ\)/{print $NF; exit}')
    SRAM_WRITE_E=$( echo "${OUTPUT}" | awk '/Total dynamic write energy per access \(nJ\)/{print $NF; exit}')
    SRAM_LEAK=$(    echo "${OUTPUT}" | awk '/Total leakage power of a bank \(mW\)/{print $NF; exit}')
    SRAM_AREA=$(    echo "${OUTPUT}" | awk '/Data array: Area \(mm2\)/{print $NF; exit}')
}

# CSV header
echo "budget,iq_size,diq_size,iq_cam_search_e_nJ,iq_cam_leak_mW,iq_cam_area_mm2,iq_payload_read_e_nJ,iq_payload_write_e_nJ,iq_payload_leak_mW,iq_payload_area_mm2,diq_read_e_nJ,diq_write_e_nJ,diq_leak_mW,diq_area_mm2,total_leak_mW,total_area_mm2" \
    > "${RESULTS_CSV}"

# Printed-table header
printf "\n%-8s %-6s %-7s %-12s %-12s %-12s %-12s\n" \
    "Budget" "IQ" "DIQ" "CAMsrch(pJ)" "Leak(mW)" "Area(mm2)" "Status"
printf -- "%-8s %-6s %-7s %-12s %-12s %-12s %-12s\n" \
    "------" "--" "---" "-----------" "--------" "---------" "------"

PREV_BUDGET=-1
for PAIR in "${CONFIGS[@]}"; do
    # Skip empty array slots (can happen if --pairs gets leading/trailing space)
    [[ -z "${PAIR// }" ]] && continue

    if [[ ! "${PAIR}" =~ ^[0-9]+-[0-9]+$ ]]; then
        echo "ERROR: pair '${PAIR}' is not in IQ-DIQ format (e.g. 160-0)" >&2
        exit 1
    fi
    IQ="${PAIR%-*}"
    DIQ="${PAIR#*-}"
    B=$(( IQ + DIQ ))

    # Blank line between budget groups in the printed table (only)
    if (( PREV_BUDGET != -1 && B != PREV_BUDGET )); then
        printf "\n"
    fi
    PREV_BUDGET=$B

    {
        # --- 1. iq_cam.cfg at IQ entries ---
        IQCAM_SIZE=$(( IQ * IQ_TAG_BYTES ))
        IQCAM_BUS=$(( IQ_TAG_BYTES * 8 ))
        sed -e "s|^-size (bytes).*|-size (bytes) ${IQCAM_SIZE}|" \
            -e "s|^-block size (bytes).*|-block size (bytes) ${IQ_TAG_BYTES}|" \
            -e "s|^-read-write port.*|-read-write port ${IQ_RW_PORTS}|" \
            -e "s|^-search port.*|-search port ${IQ_SEARCH_PORTS}|" \
            -e "s|^-output/input bus width.*|-output/input bus width ${IQCAM_BUS}|" \
            -e "s|^-technology (u).*|-technology (u) ${TECH_UM}|" \
            "${CFG_DIR}/iq_cam.cfg" > "${TMP_IQCAM}"
        OUTPUT=$(${CACTI} -infile "${TMP_IQCAM}" 2>/dev/null) || true
        if echo "${OUTPUT}" | grep -qiE "cache size must|invalid|error" || \
           ! echo "${OUTPUT}" | grep -q "Access time"; then
            IQCAM_STATUS="FAIL"
            IQCAM_SEARCH_E="" IQCAM_LEAK="" IQCAM_AREA=""
        else
            IQCAM_STATUS="OK"
            parse_iq_cam
        fi

        # --- 2. iq_cam_payload.cfg at IQ entries ---
        IQPAY_SIZE=$(( IQ * IQ_PAYLOAD_BYTES ))
        IQPAY_BUS=$(( IQ_PAYLOAD_BYTES * 8 ))
        sed -e "s|^-size (bytes).*|-size (bytes) ${IQPAY_SIZE}|" \
            -e "s|^-block size (bytes).*|-block size (bytes) ${IQ_PAYLOAD_BYTES}|" \
            -e "s|^-read-write port.*|-read-write port ${IQ_PAYLOAD_PORTS}|" \
            -e "s|^-output/input bus width.*|-output/input bus width ${IQPAY_BUS}|" \
            -e "s|^-technology (u).*|-technology (u) ${TECH_UM}|" \
            "${CFG_DIR}/iq_cam_payload.cfg" > "${TMP_IQPAY}"
        OUTPUT=$(${CACTI} -infile "${TMP_IQPAY}" 2>/dev/null) || true
        if echo "${OUTPUT}" | grep -qiE "cache size must|invalid|error" || \
           ! echo "${OUTPUT}" | grep -q "Access time"; then
            IQPAY_STATUS="FAIL"
            IQPAY_READ_E="" IQPAY_WRITE_E="" IQPAY_LEAK="" IQPAY_AREA=""
        else
            IQPAY_STATUS="OK"
            parse_sram
            IQPAY_READ_E="${SRAM_READ_E}"
            IQPAY_WRITE_E="${SRAM_WRITE_E}"
            IQPAY_LEAK="${SRAM_LEAK}"
            IQPAY_AREA="${SRAM_AREA}"
        fi

        # --- 3. diq_sram.cfg at DIQ entries ---
        if (( DIQ > 0 )); then
            DIQ_SIZE=$(( DIQ * DIQ_ENTRY_BYTES ))
            DIQ_BUS=$(( DIQ_ENTRY_BYTES * 8 ))
            sed -e "s|^-size (bytes).*|-size (bytes) ${DIQ_SIZE}|" \
                -e "s|^-block size (bytes).*|-block size (bytes) ${DIQ_ENTRY_BYTES}|" \
                -e "s|^-read-write port.*|-read-write port ${DIQ_PORTS}|" \
                -e "s|^-output/input bus width.*|-output/input bus width ${DIQ_BUS}|" \
                -e "s|^-technology (u).*|-technology (u) ${TECH_UM}|" \
                "${CFG_DIR}/diq_sram.cfg" > "${TMP_DIQ}"
            OUTPUT=$(${CACTI} -infile "${TMP_DIQ}" 2>/dev/null) || true
            if echo "${OUTPUT}" | grep -qiE "cache size must|invalid|error" || \
               ! echo "${OUTPUT}" | grep -q "Access time"; then
                DIQ_STATUS="FAIL"
                DIQ_READ_E="" DIQ_WRITE_E="" DIQ_LEAK="" DIQ_AREA=""
            else
                DIQ_STATUS="OK"
                parse_sram
                DIQ_READ_E="${SRAM_READ_E}"
                DIQ_WRITE_E="${SRAM_WRITE_E}"
                DIQ_LEAK="${SRAM_LEAK}"
                DIQ_AREA="${SRAM_AREA}"
            fi
        else
            # DIQ=0: no run, zero contribution
            DIQ_READ_E="0" DIQ_WRITE_E="0" DIQ_LEAK="0" DIQ_AREA="0"
            DIQ_STATUS="OK"
        fi

        # Sum leakage and area across components (only when parts that
        # exist returned OK; otherwise leave totals blank)
        TOTAL_STATUS="OK"
        if [[ "${IQCAM_STATUS}" != "OK" || "${IQPAY_STATUS}" != "OK" || "${DIQ_STATUS}" != "OK" ]]; then
            TOTAL_STATUS="PARTIAL"
        fi
        if [[ "${TOTAL_STATUS}" == "OK" ]]; then
            TOTAL_LEAK=$(echo "${IQCAM_LEAK} + ${IQPAY_LEAK} + ${DIQ_LEAK}" | bc -l)
            TOTAL_AREA=$(echo "${IQCAM_AREA} + ${IQPAY_AREA} + ${DIQ_AREA}" | bc -l)
        else
            TOTAL_LEAK=""
            TOTAL_AREA=""
        fi

        # CSV row
        echo "${B},${IQ},${DIQ},${IQCAM_SEARCH_E},${IQCAM_LEAK},${IQCAM_AREA},${IQPAY_READ_E},${IQPAY_WRITE_E},${IQPAY_LEAK},${IQPAY_AREA},${DIQ_READ_E},${DIQ_WRITE_E},${DIQ_LEAK},${DIQ_AREA},${TOTAL_LEAK},${TOTAL_AREA}" \
            >> "${RESULTS_CSV}"

        # Pretty-print row (CAM search energy in pJ for readability)
        if [[ -n "${IQCAM_SEARCH_E}" ]]; then
            CAMSRCH_PJ=$(echo "${IQCAM_SEARCH_E} * 1000" | bc -l | awk '{printf "%.2f", $1}')
        else
            CAMSRCH_PJ="-"
        fi
        if [[ -n "${TOTAL_LEAK}" ]]; then
            LEAK_FMT=$(echo "${TOTAL_LEAK}" | awk '{printf "%.2f", $1}')
            AREA_FMT=$(echo "${TOTAL_AREA}" | awk '{printf "%.4f", $1}')
        else
            LEAK_FMT="-" AREA_FMT="-"
        fi
        printf "%-8s %-6s %-7s %-12s %-12s %-12s %-12s\n" \
            "${B}" "${IQ}" "${DIQ}" "${CAMSRCH_PJ}" "${LEAK_FMT}" "${AREA_FMT}" "${TOTAL_STATUS}"
    }
done

printf "\nConfig: IQ_entry=%d B  DIQ_entry=%d B  tech=%d nm\n" \
    "${IQ_ENTRY_BYTES}" "${DIQ_ENTRY_BYTES}" "${TECH_NM}"
printf "Results written to: %s\n\n" "${RESULTS_CSV}"
