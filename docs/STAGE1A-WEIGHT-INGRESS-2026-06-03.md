# Stage1A Weight Ingress - 2026-06-03

## Scope

This note records the first Stage1 silicon sub-harness after the v28 reverify
bitstream was loaded on KV260.

It is intentionally narrower than full GEMM. It verifies:

- host-side signed INT4 lane packing: 32 lanes per 128-bit AXIS beat
- HP0 upper-weight and HP1 lower-weight DataMover issue
- equal-length paired weight streams: 64 beats, 1024 bytes per lane stream
- all observed HP0/HP1 DataMover status payloads are tag-matched OKAY
- cleanup reload leaves the board able to run Stage0 again

It does not verify full GEMM numeric correctness.

## Why This Split Exists

Current RTL connects GEMM weights as continuous HP streams:

- `NPU_top.sv`: HP0 `tdata[i*4+:4]` -> GEMM upper INT4 lane
- `NPU_top.sv`: HP1 `tdata[i*4+:4]` -> GEMM lower INT4 lane
- `mem_HP_buffer.sv`: HP0/HP1 are CDC FIFOs from AXI HP to core clock
- `GEMM_weight_dispatcher.sv`: `weight_valid = fifo_upper_valid & fifo_lower_valid`

The dispatcher ready path is always asserted, so a naive "preload weights, then
dispatch GEMM later" flow can drain weights before the GEMM instruction/fmap
timing reaches the PE array. A valid full-GEMM silicon harness must therefore
coordinate HP0/HP1 weight streaming with fmap and GEMM instruction issue.

## New Harness

File:

```text
debug/stage1_weight_ingress_smoke.py
```

Local script SHA-256:

```text
3a9d8a34e0d679be4cbe4c3932a9b1979f105229315eb9e9a3dc2004a3339a78
```

The script:

1. checks dmesg for recent fatal AXI/SError signatures
2. reloads `pccx_npu_bd`
3. builds deterministic signed INT4 upper/lower payloads
4. allocates two CMA buffers and resolves 32-bit physical addresses
5. issues HP0 and HP1 DataMover commands back to back
6. polls the first status for each channel
7. pops remaining status FIFO payloads and verifies every payload is OKAY with
   the expected tag
8. dumps cmd/status FIFO state before and after
9. performs cleanup reload

## Board Evidence

### v29 Reverify

Active bitstream:

```text
md5 06fcc0d825ee8ffdb782d098131cf6b7
label v29 inst-align 20260603T064753Z
```

Run:

```text
debug/results/board_v29_instalign_stage1_weight_ingress_20260603T073818Z.log
SHA-256 1124f2b0f21580663d8edba21f8d80e673fa6795aeccee8123b08650c93f259a
RESULT: PASS_WEIGHT_INGRESS
```

Follow-up Stage0:

```text
debug/results/board_v29_instalign_post_stage1_stage0_20260603T073846Z.log
SHA-256 b479bacb3d19a4f9f44b2da7bac42b0f63eaa9a2e19a8dea1ae5de9c9315bf94
RESULT: PASS
```

### v28 Original Run

Active bitstream:

```text
md5 2abbbae6b3333739ec6ab45e06532cd6
label v28 reverify 20260603T034200Z
```

Primary run:

```text
debug/results/board_v28_stage1_weight_ingress_popall_20260603T061819Z/
stage1_weight_ingress_popall_rc=0
```

Key observed lines:

```text
upper beat0 little-endian hex=98badcfe1032547698badcfe10325476
lower beat0 little-endian hex=67452301efcdab8967452301efcdab89
HP0 status payloads checked=3
HP1 status payloads checked=3
RESULT: PASS_WEIGHT_INGRESS
```

Log SHA-256:

```text
dbc0d407e269819fedbebda39f5bbe83f01f954ca22e77132630e100401ce463  stage1_weight_ingress.log
28bd2dc260ece700f99d3509311bbaf08e174b035cb643b21102fab22780f169  summary.txt
```

Follow-up Stage0 health check:

```text
debug/results/board_v28_after_stage1_weight_ingress_stage0_20260603T061835Z/
stage0_after_weight_ingress_rc=0
RESULT: PASS
```

Log SHA-256:

```text
b479bacb3d19a4f9f44b2da7bac42b0f63eaa9a2e19a8dea1ae5de9c9315bf94  stage0_after_weight_ingress.log
a7251eab05120dba04b822aeaa4ace9d8fe64dd760b8f9bd6dd96ed04c4c4ad6  summary.txt
```

## Checklist

| Check | Result | Evidence |
|---|---|---|
| v29 inst-align bitstream loaded | PASS | md5 `06fcc0d825ee8ffdb782d098131cf6b7` |
| dmesg fatal AXI/SError precheck | PASS | no fatal tokens in tail |
| HP0/HP1 INT4 lane packing | PASS | deterministic first-beat hex logged |
| HP0 DataMover status | PASS | 3/3 payloads OKAY, tag 0 |
| HP1 DataMover status | PASS | 3/3 payloads OKAY, tag 1 |
| status FIFO cleanup by pop-all | PASS | all six cmd/status wrappers empty after issue |
| cleanup reload | PASS | `xmutil loadapp pccx_npu_bd` returns OK |
| post-ingress Stage0 | PASS | `stage0_after_weight_ingress_rc=0` |

## Interpretation

The previous Stage1 blocker "missing HP0/HP1 INT4 weight packing harness" is
partially closed for weight ingress. HP0/HP1 can accept deterministic signed
INT4 packed streams on the active v29 board image.

This does not close full GEMM. The remaining full-GEMM work is to build a
timing-coordinated harness that streams weights while the GEMM datapath is
ready, drives fmap through the current stage0-proven path, dispatches the GEMM
instruction with correct flags, drains result writeback, and compares against a
deterministic scoreboard.
