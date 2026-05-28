# DIQ CACTI Modeling — Design Decisions and Calibration Notes

Companion to `sample_config_files/{iq_cam,iq_cam_payload,diq_sram}.cfg`,
the three per-component sweep scripts, and `design_point_sweep.sh`. Captures
*why* the model is shaped the way it is and what was changed in the most
recent calibration pass.

## What this models

The research target (per `res-goals.md`): **iso-IPC area + energy
savings** from shifting expensive CAM IQ entries into a cheaper indexed-SRAM
Delta IQ (DIQ) side queue. The DIQ holds only "delta candidate" instructions
(exactly one unready source, producer completing in `< 2` cycles) and uses
direct indexed wakeup (producer's IQ entry carries a pointer to the DIQ
slot it must drive on completion) instead of CAM broadcast.

The CACTI side supplies per-component energy/area numbers; downstream
analysis combines them with gem5 activity counts (`dep_graph_wakeups`,
`deltaWakeupMap` firings, dispatch/issue counts) to compute total
activity-weighted energy at the iso-IPC `(IQ, DIQ)` operating points.

The current pass calibrates everything to the **MagnaOpus** CPU class
(`configs/sic_parvis_magna/sic_parvis.py:127-160`), which is what
`magna.py` instantiates by default and is what the user calls "non-super"
mode. MagnaOpus is *not* the same as `BaseO3CPU.py` defaults — see
[Why MagnaOpus, not BaseO3CPU.py](#why-magnaopus-not-baseo3cpupy) below.
SuperMagnaOpus (`--super` flag) is documented in
[SuperMagnaOpus deltas](#supermagnaopus-deltas-documentation-only).

## File map

| File | What it models | Notes |
|---|---|---|
| `iq_cam.cfg` | Main IQ tag CAM (wakeup search) | 4 B/entry, 8 RW + 8 search ports |
| `iq_cam_payload.cfg` | Main IQ payload SRAM (issue/dispatch data) | 9 B/entry, 8 RW ports |
| `diq_sram.cfg` | DIQ side queue (indexed) | 12 B/entry, 4 RW ports |
| `iq_cam_sweep.sh` | Per-component sweep of tag CAM | entries ∈ {8..160} |
| `iq_cam_payload_sweep.sh` | Per-component sweep of payload SRAM | entries ∈ {8..160} |
| `diq_sram_sweep.sh` | Per-component sweep of DIQ | entries ∈ {8..160} |
| `design_point_sweep.sh` | Whole-system: 54-point grid mirroring gem5 diq.sweep.sh | combines the three components; accepts `--pairs` / `--pairs-file` |

## Why MagnaOpus, not BaseO3CPU.py

A previous pass cited `BaseO3CPU.py` defaults (802 phys regs, 192 ROB,
32/32 LSQ, 8-wide) as the calibration target. Those are *fallback* values
that the user's actual sims never run. `magna.py:39-69` instantiates
either `MagnaOpus` (default) or `SuperMagnaOpus` (`--super` flag) from
`sic_parvis.py`. Both override ROB, LSQ, and phys-reg counts; the
fallback values are only used by sims that don't go through magna.py.

For this pass: target is **MagnaOpus**. The key deltas from BaseO3CPU
that affect bit widths:

- ROB: 192 → 352 (sic_parvis.py:137) → ROB pointer widens 8 b → 9 b
- LQ / SQ: 32 / 32 → 128 / 72 (sic_parvis.py:140-141) → LSQ slot pointer widens 5 b → 7 b
- PRF: 256 int + 256 fp → 280 int + 224 fp (sic_parvis.py:144-145); vec / vec-pred / mat inherit BaseO3CPU defaults (256 / 32 / 2). Total 794, still 10-bit tag.
- Pipeline width: issue / wb / commit = 8 (sic_parvis.py:133-135); dispatch inherits BaseO3CPU = 8. Port counts unchanged.

## Bit-level entry accounting

All citations are to `/home/crd/master/gem5/configs/sic_parvis_magna/sic_parvis.py`
unless noted. Lines without an override fall through to `BaseO3CPU.py`.

| gem5 parameter | Value | Source | Derived width |
|---|---|---|---|
| numPhysIntRegs  | 280 | sic_parvis.py:144 | — |
| numPhysFloatRegs | 224 | sic_parvis.py:145 | — | 
| numPhysVecRegs  | 256 | (inherited) BaseO3CPU | — |
| numPhysVecPredRegs | 32 | (inherited) BaseO3CPU | — |
| numPhysMatRegs  | 2   | (inherited) BaseO3CPU | — |
| **Σ phys regs** | **794** | sum | **PRF tag = 10 bits** (2¹⁰=1024) |
| numROBEntries | **352** | sic_parvis.py:137 | **ROB ptr = 9 bits** (2⁹=512) |
| numIQEntries | 120 (sweep 8…160) | sic_parvis.py:138 + magna.py:46 | IQ slot ptr = 8 bits |
| numDeltaIQEntries | 40 (sweep 0…150) | sic_parvis.py:139 + magna.py:47 | DIQ slot ptr = 8 bits |
| LQEntries / SQEntries | **128 / 72** | sic_parvis.py:140-141 | **LSQ ptr = 7 bits** |
| dispatch/issue/wb width | 8 / 8 / 8 | dispatch inherited; issue/wb at sic_parvis.py:133-134 | port counts |
| OpClass count (Num_OpClass) | 77 | `cpu/op_class.hh` | OpClass = 7 bits |
| FUs in DefaultFUPool | 25 | `cpu/o3/FuncUnitConfig.py` (no override in MagnaOpus) | FU port ID = 5 bits |

### Regular IQ — tag CAM half (`iq_cam.cfg`)

Only the bits that need associative comparison against a broadcast bus live
in CAM cells.

| Field | Width | Notes |
|---|---|---|
| Source PRF tag × 3 | 3 × 10 = 30 b | All 3 sources searched every broadcast. Per-source ready bits gate the match-line output but live in the payload, not in the CAM. |
| **Total CAM cells** | **30 b → 4 B** | 2 bits of byte-alignment slack |

### Regular IQ — payload SRAM half (`iq_cam_payload.cfg`)

Read by entry slot index on issue and dispatch; written on dispatch and on
writeback (ready-bit updates).

| Field | Width | Notes |
|---|---|---|
| Source ready bit × 3 | 3 b | one per source operand |
| Destination PRF tag | 10 b | drives PRF write at writeback |
| OpClass | 7 b | 77 op classes |
| FU port ID | 5 b | 25 FUs in DefaultFUPool |
| ROB pointer | **9 b** | 352-entry ROB (sic_parvis.py:137) |
| LSQ slot pointer | **7 b** | LQ=128 / SQ=72 (sic_parvis.py:140-141); single field, load/store type from OpClass |
| Immediate | **17 b** | 16-bit value + 1 sign bit |
| Status: valid / issued / squashed | 3 b | hardware-visible state only |
| DIQ-consumer back-pointer | 1 + 8 = 9 b | valid bit + 8-bit DIQ slot ptr (covers DIQ up to 150 entries, gem5 sweep max); producer drives the DIQ ready-bit on completion (the indexed-wakeup mechanism replacing the simulator-only `deltaWakeupMap`) |
| **Total payload** | **70 b → 9 B** | down from 11 B after the immediate field shrank 32 → 17 b |

### DIQ entry (`diq_sram.cfg`)

Same logical content as a regular IQ entry, minus the CAM/payload split,
plus an LSQ pointer (the DIQ holds memory ops — see correction below),
minus the producer-side DIQ back-pointer (that lives on the *producer's* IQ
entry, not on the consumer's DIQ entry). No CAM cells; wakeup is indexed.

| Field | Width | Notes |
|---|---|---|
| Source PRF tag × 3 | 30 b | plain SRAM, read at issue to drive PRF reads — never associatively compared |
| Source ready bit × 3 | 3 b | the delta source's bit is what gets flipped on indexed wakeup |
| Destination PRF tag | 10 b | |
| OpClass | 7 b | |
| FU port ID | 5 b | |
| ROB pointer | **9 b** | 352-entry ROB (sic_parvis.py:137) |
| LSQ slot pointer | **7 b** | LQ=128 / SQ=72 (sic_parvis.py:140-141); DIQ holds mem ops (verified — see below) |
| Immediate | **17 b** | 16-bit value + 1 sign bit |
| Status: valid / issued / squashed | 3 b | |
| **Total DIQ entry** | **91 b → 12 B** | down from 14 B after the immediate field shrank 32 → 17 b (CACTI body: `-block size` 14→12, bus 112→96) |

### What is NOT in any entry

Called out so future readers don't add them back:

- **`deltaWakeupMap`** (`inst_queue.hh:426`) — `unordered_map<seqNum, vector<inst>>`
  is a simulator data structure. Hardware uses the producer-side DIQ
  back-pointer in the IQ payload entry.
- **`deltaVec`** per-source `{bool dependent; int64_t seqNum; int64_t cycleDist}`
  (`dyn_inst.hh:101-106`) — simulator-only metadata used by `isDeltaCand()`
  at the rename stage, never reaches the DIQ.
- **Status bitset bits 4–19** (`dyn_inst.hh:158-188`) — `ListIt` iterator
  handles, trace flags, RegsRenamed, etc. are simulator state.
- **64-bit InstSeqNum** — simulator ordering token; real hardware uses the
  ROB pointer for the same purpose.
- **StaticInst byte stream** — re-fetched from icache on misprediction; not
  replicated per IQ entry in real hardware.

## Why the regular IQ is modeled as two separate configs

Splitting the regular CAM-based IQ across `iq_cam.cfg` (the tag CAM) and
`iq_cam_payload.cfg` (the payload SRAM) is both a CACTI necessity and a
faithful model of the hardware.

### Why they have to be separate in CACTI

CACTI offers only two cache types:

- `cache type cam` — every bit is a CAM cell (associative match on every bit)
- `cache type ram` — pure indexed SRAM, no associative search

There's no hybrid "narrow-CAM + wide-SRAM" cache type. If you forced the
whole 13 B entry into one CAM, every byte of the payload would be modeled
as expensive CAM cells (~2× area vs SRAM, plus match-line logic on every
bit) — massively overstating cost. If you forced it into a single RAM,
you'd lose the associative search entirely. Two configs is the only way
to get faithful numbers for the hybrid.

### Why hardware actually splits them this way

The split mirrors real OoO IQ design. Only the source-tag bits need to be
CAM-searched on a result broadcast — the rest of the entry (opcode, dest
tag, immediate, ready bits, status, ROB ptr, LSQ ptr, DIQ-consumer
back-pointer) is read out by index after the tag CAM produces a match line.
So a real IQ is physically:

- **Tag CAM** — 4 B wide (3 src tags × 10 bits = 30 bits), CAM cells, with
  8 search ports for the 8 result broadcast buses
- **Payload SRAM** — 9 B wide (70 b), plain SRAM cells, no search ports

Different cell types, different port counts, different access patterns.
They're already separate arrays in the floorplan, so modeling them as
separate CACTI configs lines up with physical reality.

### Measured separately — combined with different activity factors

Each IQ event hits a different subset of the two arrays:

| Event | Tag CAM | Payload SRAM |
|---|---|---|
| Dispatch (write a new uop) | write energy | write energy |
| Result broadcast (wakeup) | **search energy** | — |
| Issue (read selected uop) | read energy | read energy |

`N_broadcast` is typically much larger than `N_dispatch` or `N_issue` (one
per FU completion per cycle on every active port), which is exactly why the
CAM search dominates IQ dynamic energy and why shrinking the tag CAM is the
energy lever the DIQ is designed to pull.

This is why `design_point_results.csv` keeps `iq_cam_search_e_nJ`,
`iq_payload_read_e_nJ`, `iq_payload_write_e_nJ`, `diq_read_e_nJ`,
`diq_write_e_nJ`, and `diq_wakeup_e_nJ` as separate columns rather than
summing them. When you combine with gem5 stats you weight each one by its
own per-cycle event count — see the
[activity-weighted combinator](#producing-final-results-the-activity-weighted-combinator)
later in this document.

For leakage and area, the columns just get summed — those are static, no
activity weighting needed.

### Where the DIQ fits

The DIQ (`diq_sram.cfg`) is a single SRAM array — no CAM half. It still
stores source PRF tags (so the FU can read PRF at issue) but as plain SRAM
cells, never associatively compared. So total IQ-side energy is:

```
E_IQ      = E(iq_cam.cfg)         + E(iq_cam_payload.cfg)
E_DIQ     = E(diq_sram.cfg)
E_total   = E_IQ + E_DIQ
```

The headline trade-off the research is measuring: as entries shift from the
IQ side to the DIQ side, the expensive `iq_cam.cfg` search-energy column
shrinks (smaller CAM, fewer entries to broadcast against), and the cheaper
`diq_sram.cfg` columns grow. The combinator formula at the end of this
document is what turns those raw coefficients plus gem5 activity counts
into a single energy number per design point.

## Entry-width history

Three calibration cleanups have happened, in chronological order:

1. **Bit-level tightening pass.** The original configs sized entries at
   22 B (regular IQ) and 18 B (DIQ) based on byte-rounded estimates ("~1 B
   for a 1-bit ready bit", "padded to 18 B alignment with microarch
   metadata"). That padding hid ~70 bits of slack per entry. A subsequent
   pass computed every field to its actual bit width, summed once, then
   rounded the total to bytes — yielding 11 B (payload) and 13 B (DIQ)
   under a BaseO3CPU calibration.

2. **MagnaOpus recalibration.** The bit-level pass cited `BaseO3CPU.py`
   line numbers as the source for ROB / LSQ widths. But the user's actual
   sims run MagnaOpus, which has 352 ROB and LQ=128 / SQ=72. That widens
   ROB pointer (8→9 b) and LSQ pointer (5→7 b); payload stayed at 11 B
   after rounding, DIQ grew to 14 B.

3. **17-bit immediate (this pass).** Workload-driven decision: the
   immediate field shrinks 32 → 17 b (16-bit value + 1 sign bit). That
   drops payload 85 → 70 b (11 → 9 B) and DIQ 106 → 91 b (14 → 12 B).

| Structure | Original | Bit-level | MagnaOpus | 17-b imm (this pass) |
|---|---|---|---|---|
| IQ tag CAM | 4 B | 4 B | 4 B | 4 B |
| IQ payload | 18 B | 11 B (81 b) | 11 B (85 b) | **9 B (70 b)** |
| DIQ entry | 18 B | 13 B (103 b) | 14 B (106 b) | **12 B (91 b)** |
| Total regular IQ entry | 22 B | 15 B | 15 B | **13 B** |

The CAM has always been tight at 4 B. Payload and DIQ have moved with
field-width assumptions; in this pass the dominant change is the
immediate field.

## Factual corrections carried over from prior passes

### 1. The DIQ holds memory operations

The original documentation (`res-goals.md:33` and earlier `modeling-plan.md`)
stated that memory operations are never routed to the DIQ. That claim is
**wrong**. Verified at:

- `inst_queue.cc:599-704` (`insert()`) — no `!isMemRef()` guard
- `iew.cc:937-949` (`dispatchInsts`) — delta candidates bypass a full IQ
  into the DIQ regardless of mem-op status
- `inst_queue.cc:1216-1230` — mem delta insts stay in `deltaInstList` past
  wakeup until commit/squash

Consequence: the DIQ entry carries an LSQ slot pointer (+7 bits under
MagnaOpus calibration) just like the regular IQ payload.

### 2. Calibrated to MagnaOpus, not BaseO3CPU.py

Earlier passes cited `BaseO3CPU.py` line numbers as the source for ROB,
LSQ, and PRF widths. But `magna.py` (the user's actual sim entrypoint)
instantiates `MagnaOpus` / `SuperMagnaOpus` from `sic_parvis.py`, which
overrides several of those defaults. Specifically MagnaOpus has 352 ROB
(not 192) and LQ=128 / SQ=72 (not 32/32), which widens per-entry pointers:

| Field | BaseO3CPU calibration | MagnaOpus calibration |
|---|---|---|
| ROB pointer | 8 b (192 ROB) | **9 b** (352 ROB) |
| LSQ slot pointer | 5 b (32/32) | **7 b** (128/72) |
| PRF tag | 10 b (802 regs) | 10 b (794 regs — coincidentally same after rounding) |

Effect on entry widths (under the BaseO3CPU calibration that preceded
this one — does not include the 17-bit immediate change):
- IQ payload: 81 → 85 b → still 11 B (byte rounding absorbs it)
- DIQ entry: 103 → 106 b → **13 → 14 B** (CACTI body change)
- IQ tag CAM: 30 → 30 b → 4 B (unchanged)

(After the 17-bit immediate change in this pass: payload 70 b → 9 B and
DIQ entry 91 b → 12 B; see [Entry-width history](#entry-width-history).)

Ports are unchanged because MagnaOpus pipeline width is still 8
(`issue/wb/commit = 8` at sic_parvis.py:133-135; dispatch inherited from
BaseO3CPU = 8):

| Structure | Ports |
|---|---|
| IQ tag CAM | 8 RW + 8 search |
| IQ payload | 8 RW |
| DIQ | 4 RW (side-queue traffic, not pipeline-width) |

The DIQ stays at 4 RW because it's a side queue — its traffic is the
delta-candidate fraction of dispatch (≈2/cycle peak) plus the woken
fraction of issue (≈2/cycle peak), not pipeline-width.

## Wakeup-energy approximation

The hardware DIQ wakeup operation is a single-bit flip of the delta
source's ready bit — not a full payload write. The full row-write energy
overstates wakeup cost by 10–20× (bitline drivers don't scale perfectly
linearly with bit count, but flipping 1 bit ≠ flipping 96).

`design_point_sweep.sh` emits a separate `diq_wakeup_e_nJ` column computed
as `diq_write_e_nJ / (diq_entry_bytes × 8)` — at the 12 B default,
divisor = 96. This is an approximation, but ~10× closer to truth than
charging the full row write. The full-row `diq_write_e_nJ` is still
emitted for actual dispatch writes (which *do* write the full entry).

Downstream activity-weighted DIQ dynamic energy:

```
diq_dyn_E = N_dispatch_to_diq * diq_write_e
          + N_diq_wakeup       * diq_wakeup_e
          + N_diq_issue        * diq_read_e
```

where `N_diq_wakeup` is the gem5 count of `deltaWakeupMap` firings.

## SuperMagnaOpus deltas (documentation only)

For reference. The `--super` flag on `magna.py` instantiates
`SuperMagnaOpus` (`sic_parvis.py:183-217`) instead of `MagnaOpus`. The
bit-width deltas relative to the MagnaOpus calibration this file targets:

| Param | MagnaOpus | SuperMagnaOpus | Source |
|---|---|---|---|
| Σ phys regs | 794 → **10 b** | 1314 (512+512+256+32+2) → **11 b** | sic_parvis.py:200-201 (int=fp=512); vec/vp/mat inherited |
| numROBEntries | 352 → 9 b | 512 → 9 b (unchanged) | sic_parvis.py:194 |
| LQ / SQ | 128 / 72 → 7 b | 512 / 512 → **9 b** | sic_parvis.py:197-198 |
| dispatchWidth | 8 (inherited) | **10** | sic_parvis.py:189 |
| issueWidth / wbWidth | 8 / 8 | **12 / 12** | sic_parvis.py:190-191 |
| FU count | 25 (DefaultFUPool) → 5 b | 30 (SuperMagnaOpusFUPool) → 5 b (still fits) | sic_parvis.py:166-179 |

Recomputed entry widths under SuperMagnaOpus (with the 17-bit immediate
this pass adopted):

- IQ tag CAM: 3 × 11 = 33 b → **5 B** (was 4 B under MagnaOpus)
- IQ payload: 3 + 11 + 7 + 5 + 9 + 9 + 17 + 3 + (1+8) = **73 b → 10 B**
  (vs 9 B under MagnaOpus — the wider PRF / LSQ pointers push it past
  the 8-b/72-b boundary)
- DIQ entry: 33 + 3 + 11 + 7 + 5 + 9 + 9 + 17 + 3 = **97 b → 13 B**
  (vs 12 B under MagnaOpus)

So a Super recalibration changes **port counts** (8→12 search, 8→10/12
RW), the **tag CAM block size** (4→5 B), the payload (9→10 B), and the
DIQ (12→13 B).

The per-component sweep scripts already accept port-count args, so a
SuperMagnaOpus run is a one-liner today (no config-file fork needed):

```
./iq_cam_sweep.sh 5 10 12 22         # tag_width=5, rw=10, search=12, tech_nm
./iq_cam_payload_sweep.sh 10 12 22   # payload_width=10, ports=12, tech_nm
./diq_sram_sweep.sh 13 4 22          # entry=13, ports=4 (unchanged), tech
```

A future `--super` flag on `design_point_sweep.sh` would flip the port and
tag-CAM-byte constants in one place. Not done in this pass.

## Known limitations (deferred)

1. **CAM dispatch-write energy not in the CSV.** `design_point_sweep.sh`
   currently parses only the CAM search energy, not the dispatch-write
   energy. The regular-IQ dynamic energy on the dispatch side is therefore
   undercounted. Worth adding once a stable schema for the deferred
   `iq_cam_write_e_nJ` column lands.

2. **Sweep grid not iso-IPC-aligned.** The default 54-point grid mirrors
   the gem5 `diq.sweep.sh` CONFIGS array — budgets {8, 16, 32, 64, 96, 128,
   160} with dense IQ/DIQ splits per budget (e.g. budget=160 has 16 splits
   from 160-0 to 10-150 in steps of 10). Once gem5 produces per-workload
   iso-IPC `(IQ, DIQ)` points, re-run with
   `./design_point_sweep.sh --pairs "X-Y X-Y ..."` or
   `--pairs-file path` (one pair per line, `#` comments allowed) to evaluate
   only the iso-IPC points.

3. **22 nm tech node vs Ice Lake's 10 nm.** CACTI's lowest validated node
   is 22 nm. All absolute numbers are ~2× too high. Relative comparisons
   (IQ vs DIQ at the same node) are unaffected. Scale analytically if
   absolute figures are needed.

4. **Wakeup-port modeling.** The single-bit ready flip is approximated via
   `diq_wakeup_e_nJ = diq_write_e_nJ / entry_bits`. Linear scaling; real
   bitline-driver energy isn't perfectly linear in bit count. The
   approximation is ~10× closer to truth than charging the full row-write
   energy, but a more rigorous model would distinguish bitline driver
   energy from wordline + decode energy.

5. **DIQ peripheral overhead vs cell storage.** Even at 12 B / 4 ports,
   small DIQ arrays carry non-trivial peripheral leakage because each port
   costs decode + sense-amp logic. This is real — a property of having a
   *separate* array at all — but worth understanding when interpreting
   whether a small DIQ is "free."

6. **Monolithic unified-IQ model — overstates absolute peripheral cost.**
   The CACTI configs treat each IQ as a single UCA array
   (`-UCA bank count 1`) with the full per-cycle port count applied to
   one block — 8 RW + 8 search on the tag CAM, 8 RW on the payload, 4 RW
   on the DIQ. The *per-cycle bandwidth* this represents is realistic for
   a wide OoO core (8-wide dispatch, 8 broadcast buses, 8 issue
   reads/cycle), but real silicon doesn't build flat 16-port arrays:

   - **Real designs cluster the scheduler.** Intel Sunny Cove / AMD Zen
     split the IQ into integer, FP/vec, and memory schedulers — each with
     ~30–50 entries and only a few of the broadcast ports servicing each
     cluster. CACTI's UCA model can't represent this.
   - **Real designs bank the array.** A monolithic 160-entry × 16-port
     CAM would have monstrous bitline/match-line pitch. Production
     implementations bank into smaller sub-arrays to keep per-bank port
     count manageable.

   Consequence: absolute leakage and area numbers from
   `design_point_results.csv` are conservative upper bounds — what you'd
   get if you actually built one flat unified IQ. **Relative comparisons
   (% energy/area saved by adding a DIQ at fixed total budget) remain
   meaningful** because both sides of the comparison carry the same
   overstatement, and the model lines up with gem5's unified-IQ
   abstraction (gem5's O3 also models the IQ as a single unified structure
   rather than a clustered scheduler).

   For more realistic absolute numbers:
   - Cluster the model by running `iq_cam.cfg` at, say, 16 entries × 4
     search ports four times and summing — requires deciding how gem5's
     unified IQ maps to clusters.
   - Bank within the array by setting `-UCA bank count` > 1 in the configs
     (CACTI supports this). Reduces per-bank port count without changing
     semantics.

   Neither is done in this pass; not blocking for the iso-IPC research
   question.

## Changes made in this pass (17-bit immediate)

The immediate field shrinks 32 → 17 b (16-bit value + 1 sign bit),
cascading through every entry that carries an immediate.

| File | Change |
|---|---|
| `sample_config_files/iq_cam.cfg` | No change (CAM has no immediate field). |
| `sample_config_files/iq_cam_payload.cfg` | Header bit table: immediate 32 → 17 b, total 85 → 70 b. Body: `-size` 704 → 576 (64 × 9 B), `-block size` 11 → 9, `-output/input bus width` 88 → 72. |
| `sample_config_files/diq_sram.cfg` | Header bit table: immediate 32 → 17 b, total 106 → 91 b. Body: `-size` 196 → 168 (14 × 12 B), `-block size` 14 → 12, `-output/input bus width` 112 → 96. |
| `design_point_sweep.sh` | `IQ_ENTRY_BYTES` default 15 → 13; `DIQ_ENTRY_BYTES` 14 → 12; `diq_wakeup_e_nJ` divisor 112 → 96 (= 12 × 8). Header bit-derivation comments updated. |
| `iq_cam_sweep.sh` | No change (CAM unaffected). |
| `iq_cam_payload_sweep.sh` | `PAYLOAD_WIDTH_BYTES` default 11 → 9. Header bit table updated. |
| `diq_sram_sweep.sh` | `ENTRY_WIDTH_BYTES` default 14 → 12. Header bit table updated. |
| `zontext/modeling-plan.md` (this file) | Both bit tables and file map updated; entry-width history extended; SuperMagnaOpus deltas recomputed under 17-b immediate; combinator divisor and re-derive section updated. |

## How to re-derive the results after these changes

```
cd /home/crd/master/cacti
./design_point_sweep.sh                                 # full 54-point gem5 grid, new defaults (13 B IQ / 12 B DIQ)
./design_point_sweep.sh 15 14 22                        # reproduce previous-pass widths (32-b imm) for comparison
./design_point_sweep.sh --pairs "160-0 80-80 40-120"    # only the points you care about
./design_point_sweep.sh --pairs-file iso_ipc_points.txt # one IQ-DIQ pair per line (# comments allowed)
```

Expected effects vs the previous-pass CSV (which used the 32-b
immediate and therefore 11 B payload / 14 B DIQ):

- **iq_cam.cfg numbers**: no change (CAM has no immediate field).
- **iq_cam_payload.cfg leakage / area**: drops ~15–20% (entry 11 → 9 B,
  two fewer bytes of cell storage on the dominant array).
- **diq_sram.cfg leakage / area**: drops ~12–15% (entry 14 → 12 B).
- **diq_wakeup_e_nJ**: full-row `diq_write_e_nJ` shrinks (smaller row),
  and divisor changes 112 → 96 (≈14% smaller). Net per-event wakeup is
  roughly flat or slightly down; depends on CACTI's port/width scaling.

## Reading the output: printed table vs CSV

`design_point_sweep.sh` produces two artifacts. They contain different
information.

### Printed table (terminal summary)

| Column | What it is | Why it's shown |
|---|---|---|
| Budget / IQ / DIQ | Design point coordinates | Identifies the row |
| `CAMsrch(pJ)` | Per-broadcast tag-CAM search energy | The single biggest dynamic-energy lever the DIQ targets |
| `Leak(mW)` | Sum of static leakage across IQ CAM + IQ payload + DIQ | Aggregate idle power — sums cleanly across components |
| `Area(mm2)` | Sum of array areas | Aggregate hardware cost |
| Status | OK / PARTIAL / FAIL | Flags CACTI's 64 B CAM-floor failures |

Three numbers fit on a terminal row. That's all the table gives you.

### CSV (`design_point_results.csv`) — the full set

Six dynamic-energy columns; the table shows only one of them.

| CSV column | Per-event energy for ... | gem5 activity count it pairs with |
|---|---|---|
| `iq_cam_search_e_nJ` | Tag-CAM associative search (shown in table) | Result broadcasts (≈ FU completions per cycle) |
| `iq_payload_read_e_nJ` | Issue read of IQ payload | Issues from IQ |
| `iq_payload_write_e_nJ` | Dispatch write of IQ payload | Dispatches to IQ |
| `diq_read_e_nJ` | Issue read from DIQ | Issues from DIQ |
| `diq_write_e_nJ` | Dispatch write to DIQ | Dispatches to DIQ |
| `diq_wakeup_e_nJ` | Single ready-bit flip in DIQ (approx) | `deltaWakeupMap` firings |

Plus the static and structural columns: `iq_cam_leak_mW`,
`iq_cam_area_mm2`, `iq_payload_leak_mW`, `iq_payload_area_mm2`,
`diq_leak_mW`, `diq_area_mm2`, `total_leak_mW`, `total_area_mm2`.

Not yet captured (see [Known limitations](#known-limitations-deferred)):

- `iq_cam_write_e_nJ` — dispatch write energy on the tag CAM.

## Why leakage alone is not the energy answer

Total energy over a run is:

```
E_total = E_static + E_dynamic
        = (sum_i leakage_i) × wall_time
        + Σ_events (event_count × per_event_energy)
```

For any non-trivial workload, **dynamic typically dominates**. The CAM
search alone is on the order of pJ per broadcast at 64+ entries, fired
roughly `wbWidth × cycles` times per run — that's pJ × billions, often
more total energy than the leakage × runtime term. And we have five more
dynamic terms beyond CAM search.

`design_point_sweep.sh` cannot compute `E_total` because it doesn't know
the per-workload activity counts — those come from gem5. The CACTI numbers
are the **coefficients**; gem5 provides the **multipliers**; downstream
analysis multiplies and sums.

So the printed table is a quick-scan aid for the static metrics and the
single dominant dynamic term. The honest energy comparison requires the
full CSV plus gem5 stats.

## Producing final results: the activity-weighted combinator

Once gem5 produces per-workload-per-design-point stats — number of result
broadcasts, number of issues, number of dispatches (split by IQ vs DIQ
destination), number of `deltaWakeupMap` firings, total cycles — the
combiner formula is:

```
E_IQ_dyn  = N_broadcast       × iq_cam_search_e
          + N_dispatch_to_iq  × (iq_cam_write_e + iq_payload_write_e)
          + N_issue_from_iq   × iq_payload_read_e
          + N_diq_wakeup      × iq_payload_read_e   # back-ptr read at WB (see note)

E_DIQ_dyn = N_dispatch_to_diq × diq_write_e
          + N_diq_wakeup      × diq_wakeup_e
          + N_issue_from_diq  × diq_read_e

E_static  = (iq_cam_leak + iq_payload_leak + diq_leak) × wall_time
          = total_leak_mW × wall_time

E_total   = E_IQ_dyn + E_DIQ_dyn + E_static
```

Wall time = `cycles / clock_GHz` (the magna config uses 3.3 GHz —
`default.py:21 CLK_GHZ = 3.3`).

### Notes on the per-term coefficients

- **`iq_cam_write_e` is the deferred column.** Until it's added to the CSV,
  the combiner can either drop that term (slight undercount of IQ dispatch
  energy) or approximate it from a one-off CACTI run on the same tag CAM
  config. See [Known limitations](#known-limitations-deferred) #1.

- **DIQ-back-pointer read at writeback** (`N_diq_wakeup × iq_payload_read_e`).
  When an IQ producer's writeback fires a DIQ wakeup, it must read its own
  IQ payload entry to retrieve the 9-bit DIQ-consumer back-pointer (the
  field at +9 b per IQ entry that we added to model the indexed-wakeup
  mechanism). This is the dual on the producer side of the DIQ's
  `diq_wakeup_e` write on the consumer side. In real silicon the writeback
  path already drives many control lines from the producer's slot, so the
  back-ptr columns may ride along free of marginal cost — but charging a
  full payload read per wakeup is a defensible upper bound. Drop the term
  for a tighter (and probably more realistic) lower bound, or keep it for
  an upper bound. The energy delta between the two is small relative to
  `iq_cam_search_e × N_broadcast`.

- **CAM-driven payload ready-bit flip** is implicit. When a CAM search
  match-line fires, it directly drives the corresponding per-source ready
  bit in the payload (a single cell flip, not a write-port access). The
  energy of charging the match line is already inside `iq_cam_search_e`;
  the additional cell-flip energy is small (~1 bit out of 72 bits of
  payload row) and is not modeled separately. This is the IQ-side analog
  of the `diq_wakeup_e ≈ diq_write_e / 96` approximation.

### Pulling `N_*` from gem5 stats — DIQ now includes memory ops

Prior versions of this document and `res-goals.md:33` claimed that memory
operations are excluded from the DIQ. That claim is **wrong** — verified at
`inst_queue.cc:599-704` (`insert()` has no `!isMemRef()` guard),
`iew.cc:937-949` (delta candidates bypass full IQ into DIQ regardless of
mem-op status), and `inst_queue.cc:1216-1230` (mem delta insts stay in
`deltaInstList` past wakeup). When pulling activity counts from gem5
stats:

- `N_dispatch_to_diq` includes mem ops routed to the DIQ.
- `N_issue_from_diq` includes their issues.
- `N_diq_wakeup` includes their `deltaWakeupMap` firings.
- Correspondingly, the IQ-side counters (`N_dispatch_to_iq`,
  `N_issue_from_iq`) should exclude the mem ops that landed in the DIQ.

If a downstream extraction script previously applied a mem-op filter to
DIQ counts, remove that filter so the energy accounting matches what gem5
actually does.

### End-to-end procedure for the iso-IPC story

1. **gem5 IPC sweep.** For each workload and each `(IQ, DIQ)` operating
   point, record IPC and the activity counters above. Use `--super` and
   non-super modes as planned in `res-goals.md`.
2. **gem5 iso-IPC selection.** Per workload, find the smallest
   `(IQ, DIQ)` pair whose IPC is within tolerance of the baseline (e.g.
   `(64, 0)` for non-super, larger for super or for the Doppelganger
   160-entry comparison).
3. **CACTI run at the iso-IPC point.** If the point isn't already in the
   default 54-point grid, run
   `./design_point_sweep.sh --pairs "<IQ>-<DIQ> ..."` (or `--pairs-file
   path`) to evaluate just those points. Combine with positional args for
   non-default entry widths or tech node:
   `./design_point_sweep.sh 13 12 22 --pairs "90-70 70-90"`.
4. **Combine** per the formula above. Produce per-workload tuples of
   `(IPC_rel, E_total_rel, area_rel)` against the baseline.
5. **Headline result:** per-workload `(area, energy)` reduction at
   iso-IPC. This is the metric `res-goals.md` calls for.

A small post-processing script (Python, ~50 LOC) that reads the gem5 stats
file + `design_point_results.csv` and emits the per-workload combined
numbers would close the loop — natural next addition, not done in this
pass.
