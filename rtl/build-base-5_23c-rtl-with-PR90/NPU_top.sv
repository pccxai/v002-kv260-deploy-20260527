// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 pccxai

`include "GLOBAL_CONST.svh"
`timescale 1ns / 1ps
`include "GEMM_Array.svh"
`include "mem_IO.svh"
`include "npu_interfaces.svh"

import isa_pkg::*;
import vec_core_pkg::*;
import bf16_math_pkg::*;

// ===| Module: NPU_top — pccx v002 SoC integration wrapper |====================
// Purpose      : Top-level integration of all v002 NPU subsystems on KV260.
// Spec ref     : pccx v002 §1 (architecture overview), §6 (KV260 target).
// Target       : Xilinx Kria KV260 (xck26-sfvc784-2LV-c), ZU5EV.
// Clock        : clk_core @ 400 MHz (compute), clk_axi @ 250 MHz (HP/AXIL).
// Reset        : rst_n_core / rst_axi_n active-low. Synchronous release.
// Soft-clear   : i_clear (active-high, sync) — combined with reset wherever
//                state is latched per the local reset convention.
// Throughput   : Steady-state, dual-lane W4A8 systolic = 32 × 32 × 2 MAC/clk.
// Backpressure : HP weight FIFOs (mem_HP_buffer) provide CDC + skid; ACP fmap
//                FIFO (preprocess_fmap) holds at boundary when broadcast stalls.
//
// Architecture V2 (SystemVerilog Interface Version):
//   HPC0 / HPC1 : 256-bit Feature Map caching bus (ACP port).
//   HP0  ~ HP3  : High-throughput Weight streaming (128-bit each).
//   HPM  (MMIO) : Centralised control & VLIW instruction issuing (AXI-Lite).
//   ACP         : Coherent Result Output.
//
// Data paths (one active per ISA opcode at a time):
//   OP_GEMM  : ACP_FMAP → preprocess_fmap → systolic → normalizer → packer → ACP_RESULT
//   OP_GEMV  : ACP_FMAP → preprocess_fmap → GEMV_top (HP2/3 weights)
//   OP_MEMCPY: ACP DDR4 ↔ L2 (mem_dispatcher via ACP)
//   OP_MEMSET: Shape constant RAM write (mem_dispatcher)
//   OP_CVO   : L2 → CVO_top → L2 (mem_dispatcher ↔ CVO stream bridge)
//
// Status word (mmio_npu_stat[31:0], surfaced to AXIL_STAT_OUT):
//   bit 0    : BUSY  = fifo_full | cvo_busy | cvo_disp_busy | store_busy
//   bit 1    : DONE  = sticky CVO/STORE completion, cleared by next GEMM/CVO
//   bit 15:2 : top-level GEMM/readback debug snapshot
//   bit 31:16: mem_dispatcher debug snapshot
// ===============================================================================

module NPU_top (
    // ===| Clock & Reset |=======================================================
    input logic clk_core,
    input logic rst_n_core,

    input logic clk_axi,
    input logic rst_axi_n,

    // ===| Soft Clear (synchronous, active-high) |===============================
    input logic i_clear,

    // ===| Control Plane (MMIO) |================================================
    axil_if.slave S_AXIL_CTRL,

    // ===| HP Weight Ports — Matrix Core (Systolic) |============================
    axis_if S_AXI_HP0_WEIGHT,
    axis_if S_AXI_HP1_WEIGHT,

    // ===| HP Weight Ports — Vector Core (GEMV) |================================
    axis_if S_AXI_HP2_WEIGHT,
    axis_if S_AXI_HP3_WEIGHT,

    // ===| ACP Feature Map / Result (Full-Duplex) |==============================
    axis_if S_AXIS_ACP_FMAP,
    axis_if M_AXIS_ACP_RESULT
);

  // ===| Internal Wires — HP Weight (Core-side, post-CDC FIFO) |================
  axis_if #(.DATA_WIDTH(128)) M_CORE_HP0_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) M_CORE_HP1_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) M_CORE_HP2_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) M_CORE_HP3_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) M_CORE_FMAP_FROM_L2 ();
  axis_if #(.DATA_WIDTH(128)) S_AXI_HP0_WEIGHT_WIRE ();
  axis_if #(.DATA_WIDTH(128)) S_AXI_HP1_WEIGHT_WIRE ();
  axis_if #(.DATA_WIDTH(128)) S_AXI_HP2_WEIGHT_WIRE ();
  axis_if #(.DATA_WIDTH(128)) S_AXI_HP3_WEIGHT_WIRE ();
  axis_if #(.DATA_WIDTH(128)) S_AXIS_ACP_FMAP_WIRE ();
  axis_if #(.DATA_WIDTH(128)) M_AXIS_ACP_RESULT_WIRE ();

  assign S_AXI_HP0_WEIGHT_WIRE.tdata  = S_AXI_HP0_WEIGHT.tdata;
  assign S_AXI_HP0_WEIGHT_WIRE.tvalid = S_AXI_HP0_WEIGHT.tvalid;
  assign S_AXI_HP0_WEIGHT_WIRE.tlast  = S_AXI_HP0_WEIGHT.tlast;
  assign S_AXI_HP0_WEIGHT_WIRE.tkeep  = S_AXI_HP0_WEIGHT.tkeep;
  assign S_AXI_HP0_WEIGHT.tready      = S_AXI_HP0_WEIGHT_WIRE.tready;

  assign S_AXI_HP1_WEIGHT_WIRE.tdata  = S_AXI_HP1_WEIGHT.tdata;
  assign S_AXI_HP1_WEIGHT_WIRE.tvalid = S_AXI_HP1_WEIGHT.tvalid;
  assign S_AXI_HP1_WEIGHT_WIRE.tlast  = S_AXI_HP1_WEIGHT.tlast;
  assign S_AXI_HP1_WEIGHT_WIRE.tkeep  = S_AXI_HP1_WEIGHT.tkeep;
  assign S_AXI_HP1_WEIGHT.tready      = S_AXI_HP1_WEIGHT_WIRE.tready;

  assign S_AXI_HP2_WEIGHT_WIRE.tdata  = S_AXI_HP2_WEIGHT.tdata;
  assign S_AXI_HP2_WEIGHT_WIRE.tvalid = S_AXI_HP2_WEIGHT.tvalid;
  assign S_AXI_HP2_WEIGHT_WIRE.tlast  = S_AXI_HP2_WEIGHT.tlast;
  assign S_AXI_HP2_WEIGHT_WIRE.tkeep  = S_AXI_HP2_WEIGHT.tkeep;
  assign S_AXI_HP2_WEIGHT.tready      = S_AXI_HP2_WEIGHT_WIRE.tready;

  assign S_AXI_HP3_WEIGHT_WIRE.tdata  = S_AXI_HP3_WEIGHT.tdata;
  assign S_AXI_HP3_WEIGHT_WIRE.tvalid = S_AXI_HP3_WEIGHT.tvalid;
  assign S_AXI_HP3_WEIGHT_WIRE.tlast  = S_AXI_HP3_WEIGHT.tlast;
  assign S_AXI_HP3_WEIGHT_WIRE.tkeep  = S_AXI_HP3_WEIGHT.tkeep;
  assign S_AXI_HP3_WEIGHT.tready      = S_AXI_HP3_WEIGHT_WIRE.tready;

  assign S_AXIS_ACP_FMAP_WIRE.tdata  = S_AXIS_ACP_FMAP.tdata;
  assign S_AXIS_ACP_FMAP_WIRE.tvalid = S_AXIS_ACP_FMAP.tvalid;
  assign S_AXIS_ACP_FMAP_WIRE.tlast  = S_AXIS_ACP_FMAP.tlast;
  assign S_AXIS_ACP_FMAP_WIRE.tkeep  = S_AXIS_ACP_FMAP.tkeep;
  assign S_AXIS_ACP_FMAP.tready      = S_AXIS_ACP_FMAP_WIRE.tready;

  assign M_AXIS_ACP_RESULT.tdata        = M_AXIS_ACP_RESULT_WIRE.tdata;
  assign M_AXIS_ACP_RESULT.tvalid       = M_AXIS_ACP_RESULT_WIRE.tvalid;
  assign M_AXIS_ACP_RESULT.tlast        = M_AXIS_ACP_RESULT_WIRE.tlast;
  assign M_AXIS_ACP_RESULT.tkeep        = M_AXIS_ACP_RESULT_WIRE.tkeep;
  assign M_AXIS_ACP_RESULT_WIRE.tready  = M_AXIS_ACP_RESULT.tready;

  // ===| Internal Wires — Instruction Path |=====================================
  logic                       GEMV_op_x64_valid_wire;
  logic                       GEMM_op_x64_valid_wire;
  logic                       memcpy_op_x64_valid_wire;
  logic                       memset_op_x64_valid_wire;
  logic                       cvo_op_x64_valid_wire;

  instruction_op_x64_t        instruction;

  logic                       fifo_full_wire;

  // ===| Status backflow signals (defined later as mmio_npu_stat) |=============
  (* mark_debug = "true", keep = "true" *)logic                [31:0] mmio_npu_stat;

  // ===| [1] NPU Controller |====================================================
  npu_controller_top #() u_npu_controller_top (
      .clk    (clk_core),
      .rst_n  (rst_n_core),
      .i_clear(i_clear),

      .S_AXIL_CTRL(S_AXIL_CTRL),

      // Continuous status push so the host AXIL_STAT_OUT FIFO stays non-empty
      // (AXIL_STAT_OUT asserts s_arready only when the FIFO holds data). The
      // FIFO is 8 deep and self-throttles on overflow.
      .IN_enc_stat ({32'b0, mmio_npu_stat}),
      .IN_enc_valid(1'b1),

      .OUT_GEMV_op_x64_valid  (GEMV_op_x64_valid_wire),
      .OUT_GEMM_op_x64_valid  (GEMM_op_x64_valid_wire),
      .OUT_memcpy_op_x64_valid(memcpy_op_x64_valid_wire),
      .OUT_memset_op_x64_valid(memset_op_x64_valid_wire),
      .OUT_cvo_op_x64_valid   (cvo_op_x64_valid_wire),

      .OUT_op_x64(instruction)
  );

  // ===| [2] Global Scheduler |==================================================
  gemm_control_uop_t   GEMM_uop_wire;
  GEMV_control_uop_t   GEMV_uop_wire;
  memory_control_uop_t LOAD_uop_wire;
  logic                LOAD_uop_valid_wire;
  memory_control_uop_t STORE_uop_wire;  // latched at issue; drives result writeback
  logic                STORE_uop_valid_wire;
  memory_set_uop_t     mem_set_uop;
  cvo_control_uop_t    CVO_uop_wire;
  logic                sram_rd_start_wire;  // one-cycle pulse: start fmap broadcast
  logic                mem_set_uop_valid;

  Global_Scheduler #() u_Global_Scheduler (
      .clk_core  (clk_core),
      .rst_n_core(rst_n_core),

      .IN_GEMV_op_x64_valid  (GEMV_op_x64_valid_wire),
      .IN_GEMM_op_x64_valid  (GEMM_op_x64_valid_wire),
      .IN_memcpy_op_x64_valid(memcpy_op_x64_valid_wire),
      .IN_memset_op_x64_valid(memset_op_x64_valid_wire),
      .IN_cvo_op_x64_valid   (cvo_op_x64_valid_wire),
      .instruction           (instruction),



      .OUT_GEMM_uop         (GEMM_uop_wire),
      .OUT_GEMV_uop         (GEMV_uop_wire),
      .OUT_LOAD_uop         (LOAD_uop_wire),
      .OUT_LOAD_uop_valid   (LOAD_uop_valid_wire),
      .OUT_STORE_uop        (STORE_uop_wire),
      .OUT_STORE_uop_valid  (STORE_uop_valid_wire),
      .OUT_mem_set_uop      (mem_set_uop),
      .OUT_mem_set_uop_valid(mem_set_uop_valid),
      .OUT_CVO_uop          (CVO_uop_wire),
      .OUT_sram_rd_start    (sram_rd_start_wire)
  );

  // ===| [3] Memory Dispatcher |=================================================
  // CVO stream wires: bridge ↔ CVO_top
  logic [                 15:0] cvo_disp_data_wire;
  logic                         cvo_disp_valid_wire;
  logic                         cvo_disp_ready_wire;
  logic [                 15:0] cvo_result_wire;
  logic                         cvo_result_valid_wire;
  logic                         cvo_result_ready_wire;
  logic                         cvo_disp_busy_wire;
  logic                         store_busy_wire;
  logic                         store_done_wire;
  logic [                 15:0] mem_debug_status_wire;
  logic [`AXI_STREAM_WIDTH-1:0] packed_res_data;
  logic                         packed_res_valid;
  logic                         packed_res_ready;
  logic                         packed_res_busy;

  mem_dispatcher #() u_mem_dispatcher (
      .clk_core  (clk_core),
      .rst_n_core(rst_n_core),

      .clk_axi  (clk_axi),
      .rst_axi_n(rst_axi_n),

      .S_AXIS_ACP_FMAP  (S_AXIS_ACP_FMAP_WIRE),
      .M_AXIS_ACP_RESULT(M_AXIS_ACP_RESULT_WIRE),
      .M_AXIS_L1_FMAP   (M_CORE_FMAP_FROM_L2),

      .IN_LOAD_uop         (LOAD_uop_wire),
      .IN_LOAD_uop_valid   (LOAD_uop_valid_wire),
      .IN_STORE_uop        (STORE_uop_wire),
      .IN_store_uop_valid  (STORE_uop_valid_wire),
      .IN_mem_set_uop      (mem_set_uop),
      .IN_mem_set_uop_valid(mem_set_uop_valid),
      .IN_CVO_uop          (CVO_uop_wire),
      .IN_cvo_uop_valid    (cvo_op_x64_valid_wire),

      .OUT_cvo_data     (cvo_disp_data_wire),
      .OUT_cvo_valid    (cvo_disp_valid_wire),
      .IN_cvo_data_ready(cvo_disp_ready_wire),

      .IN_cvo_result       (cvo_result_wire),
      .IN_cvo_result_valid (cvo_result_valid_wire),
      .OUT_cvo_result_ready(cvo_result_ready_wire),

      .IN_gemm_result_data  (packed_res_data),
      .IN_gemm_result_valid (packed_res_valid),
      .OUT_gemm_result_ready(packed_res_ready),

      .OUT_fifo_full(fifo_full_wire),
      .OUT_cvo_busy(cvo_disp_busy_wire),
      .OUT_store_busy(store_busy_wire),
      .OUT_store_done(store_done_wire),
      .OUT_debug_status(mem_debug_status_wire)
  );

  // ===| [4] HP Weight Buffer (CDC FIFO: AXI → Core clock) |====================
  mem_HP_buffer #() u_HP_buffer (
      .clk_core  (clk_core),
      .rst_n_core(rst_n_core),
      .clk_axi   (clk_axi),
      .rst_axi_n (rst_axi_n),

      .S_AXI_HP0_WEIGHT(S_AXI_HP0_WEIGHT_WIRE),
      .S_AXI_HP1_WEIGHT(S_AXI_HP1_WEIGHT_WIRE),
      .S_AXI_HP2_WEIGHT(S_AXI_HP2_WEIGHT_WIRE),
      .S_AXI_HP3_WEIGHT(S_AXI_HP3_WEIGHT_WIRE),

      .M_CORE_HP0_WEIGHT(M_CORE_HP0_WEIGHT),
      .M_CORE_HP1_WEIGHT(M_CORE_HP1_WEIGHT),
      .M_CORE_HP2_WEIGHT(M_CORE_HP2_WEIGHT),
      .M_CORE_HP3_WEIGHT(M_CORE_HP3_WEIGHT)
  );

  // ===| [5] FMap Preprocessing Pipeline |=======================================
  logic [`FIXED_MANT_WIDTH-1:0] fmap_broadcast       [0:`ARRAY_SIZE_H-1];
  logic                         fmap_broadcast_valid;
  logic [  `BF16_EXP_WIDTH-1:0] cached_emax_out      [0:`ARRAY_SIZE_H-1];

  preprocess_fmap #() u_fmap_pre (
      .clk    (clk_core),
      .rst_n  (rst_n_core),
      .i_clear(i_clear),

      .S_AXIS_ACP_FMAP(M_CORE_FMAP_FROM_L2),

      .i_rd_start(sram_rd_start_wire),

      .o_fmap_broadcast(fmap_broadcast),
      .o_fmap_valid    (fmap_broadcast_valid),
      .o_cached_emax   (cached_emax_out)
  );

  // ===| [6] Systolic Array Engine (Matrix Core) |================================
  // global_inst[2:0] = flags[5:3] = {findemax, accm, w_scale}
  logic [`DSP48E2_POUT_SIZE-1:0] raw_res_sum      [0:`ARRAY_SIZE_H-1];
  logic                          raw_res_sum_valid[0:`ARRAY_SIZE_H-1];
  logic [   `BF16_EXP_WIDTH-1:0] delayed_emax_32  [0:`ARRAY_SIZE_H-1];
  logic [2:0]                    gemm_global_inst_aligned;
  logic                          gemm_global_inst_valid_aligned;

  GEMM_inst_fmap_aligner u_gemm_inst_fmap_aligner (
      .clk                   (clk_core),
      .rst_n                 (rst_n_core),
      .i_clear               (i_clear),
      .i_gemm_op_valid       (GEMM_op_x64_valid_wire),
      .i_gemm_inst_registered(GEMM_uop_wire.flags[5:3]),
      .i_fmap_valid          (fmap_broadcast_valid),
      .o_global_inst         (gemm_global_inst_aligned),
      .o_global_inst_valid   (gemm_global_inst_valid_aligned)
  );

  // ===| v002 dual-lane weight unpack |=========================================
  // HP0 / HP1 each carry a 128-bit AXIS word that holds 32 INT4 weights.
  // Slice each into a 32-element INT4 array for the systolic engine.
  localparam int WEIGHT_CNT = `HP_SINGLE_WIDTH / `INT4_WIDTH;  // 32
  logic [`INT4_WIDTH-1:0] hp0_weight_int4[0:WEIGHT_CNT-1];
  logic [`INT4_WIDTH-1:0] hp1_weight_int4[0:WEIGHT_CNT-1];
  genvar wi;
  generate
    for (wi = 0; wi < WEIGHT_CNT; wi++) begin : g_weight_unpack
      assign hp0_weight_int4[wi] = M_CORE_HP0_WEIGHT.tdata[wi*`INT4_WIDTH+:`INT4_WIDTH];
      assign hp1_weight_int4[wi] = M_CORE_HP1_WEIGHT.tdata[wi*`INT4_WIDTH+:`INT4_WIDTH];
    end
  endgenerate

  GEMM_systolic_top #() u_systolic_engine (
      .clk    (clk_core),
      .rst_n  (rst_n_core),
      .i_clear(i_clear),

      .global_weight_valid(M_CORE_HP0_WEIGHT.tvalid),
      .global_inst        (gemm_global_inst_aligned),
      .global_inst_valid  (gemm_global_inst_valid_aligned),

      .IN_fmap_broadcast      (fmap_broadcast),
      .IN_fmap_broadcast_valid(fmap_broadcast_valid),
      .IN_cached_emax_out     (cached_emax_out),

      // v002 dual-lane weights: HP0 → upper INT4 channel, HP1 → lower.
      // Both 128-bit AXIS streams are unpacked into 32 × INT4 arrays by a
      // simple bit-slice assign just before this instantiation.
      .IN_weight_upper      (hp0_weight_int4),
      .IN_weight_upper_valid(M_CORE_HP0_WEIGHT.tvalid),
      .IN_weight_upper_ready(M_CORE_HP0_WEIGHT.tready),
      .IN_weight_lower      (hp1_weight_int4),
      .IN_weight_lower_valid(M_CORE_HP1_WEIGHT.tvalid),
      .IN_weight_lower_ready(M_CORE_HP1_WEIGHT.tready),

      .raw_res_sum      (raw_res_sum),
      .raw_res_sum_valid(raw_res_sum_valid),
      .delayed_emax_32  (delayed_emax_32)
  );

  // ===| [7] Result Normalizers (one per systolic column) |======================
  logic [  `BF16_WIDTH-1:0] norm_res_seq        [0:`ARRAY_SIZE_H-1];
  logic                     norm_res_seq_valid  [0:`ARRAY_SIZE_H-1];
  logic [`ARRAY_SIZE_H-1:0] raw_res_valid_bits;
  logic [`ARRAY_SIZE_H-1:0] norm_res_valid_bits;
  logic signed [`DSP48E2_POUT_SIZE-1:0] recovered_res_sum[0:`ARRAY_SIZE_H-1];

  genvar n;
  generate
    for (n = 0; n < `ARRAY_SIZE_H; n++) begin : gen_norm
      assign raw_res_valid_bits[n]  = raw_res_sum_valid[n];
      assign norm_res_valid_bits[n] = norm_res_seq_valid[n];

      GEMM_dual_mac_recover u_dual_mac_recover (
          .in_p_accum(raw_res_sum[n]),
          .out_sum   (recovered_res_sum[n])
      );

      gemm_result_normalizer u_norm_seq (
          .clk      (clk_core),
          .rst_n    (rst_n_core),
          .clear    (i_clear | GEMM_op_x64_valid_wire),
          .data_in  (recovered_res_sum[n]),
          .e_max    (delayed_emax_32[n]),
          .valid_in (raw_res_sum_valid[n]),
          .data_out (norm_res_seq[n]),
          .valid_out(norm_res_seq_valid[n])
      );
    end
  endgenerate

  // ===| [8] Result Packer |=====================================================
  FROM_gemm_result_packer #() u_packer (
      .clk          (clk_core),
      .rst_n        (rst_n_core),
      .clear        (i_clear | GEMM_op_x64_valid_wire),
      .capture_enable(store_busy_wire),
      .row_res      (norm_res_seq),
      .row_res_valid(norm_res_seq_valid),
      .packed_data  (packed_res_data),
      .packed_valid (packed_res_valid),
      .packed_ready (packed_res_ready),
      .o_busy       (packed_res_busy)
  );

  // ===| [9] Vector Core (GEMV) |================================================
  // Unpack 128-bit flat HP bus → 32 × INT4 per lane before feeding GEMV_top.
  // HP2 → lane A, HP3 → lane B;  C/D tied to zero (2-lane configuration).
  localparam int GemvWeightCnt = mem_pkg::HpSingleWeightCnt;  // 32 weights per port
  localparam int GemvWeightW = mem_pkg::WeightBitWidth;  // 4-bit INT4

  logic [GemvWeightW-1:0] gemv_weight_A[0:GemvWeightCnt-1];
  logic [GemvWeightW-1:0] gemv_weight_B[0:GemvWeightCnt-1];
  logic [GemvWeightW-1:0] gemv_weight_C[0:GemvWeightCnt-1];
  logic [GemvWeightW-1:0] gemv_weight_D[0:GemvWeightCnt-1];

  genvar w;
  generate
    for (w = 0; w < GemvWeightCnt; w++) begin : gen_gemv_unpack
      assign gemv_weight_A[w] = M_CORE_HP2_WEIGHT.tdata[w*GemvWeightW+:GemvWeightW];
      assign gemv_weight_B[w] = M_CORE_HP3_WEIGHT.tdata[w*GemvWeightW+:GemvWeightW];
      assign gemv_weight_C[w] = '0;
      assign gemv_weight_D[w] = '0;
    end
  endgenerate

  // num_recur: number of fmap accumulation rounds = vector length / broadcast width.
  // size_ptr_addr is a 6-bit shape pointer; actual cycle count resolved by scheduler.
  logic [16:0] gemv_num_recur;
  logic        gemv_activated_lane[0:VecCoreDefaultCfg.num_gemv_pipeline-1];

  assign gemv_num_recur      = {11'b0, GEMV_uop_wire.size_ptr_addr};
  assign gemv_activated_lane = '{default: 1'b0};

  GEMV_top #(
      .param(VecCoreDefaultCfg)
  ) u_GEMV_top (
      .clk  (clk_core),
      .rst_n(rst_n_core),

      .IN_weight_valid_A(M_CORE_HP2_WEIGHT.tvalid),
      .IN_weight_valid_B(M_CORE_HP3_WEIGHT.tvalid),
      .IN_weight_valid_C(1'b0),
      .IN_weight_valid_D(1'b0),

      .IN_weight_A(gemv_weight_A),
      .IN_weight_B(gemv_weight_B),
      .IN_weight_C(gemv_weight_C),
      .IN_weight_D(gemv_weight_D),

      .OUT_weight_ready_A(M_CORE_HP2_WEIGHT.tready),
      .OUT_weight_ready_B(M_CORE_HP3_WEIGHT.tready),
      .OUT_weight_ready_C(),
      .OUT_weight_ready_D(),

      .IN_fmap_broadcast      (fmap_broadcast),
      .IN_fmap_broadcast_valid(fmap_broadcast_valid),
      .IN_num_recur           (gemv_num_recur),
      .IN_cached_emax_out     (cached_emax_out),
      .IN_activated_lane      (gemv_activated_lane),

      .OUT_final_fmap_A(),
      .OUT_final_fmap_B(),
      .OUT_final_fmap_C(),
      .OUT_final_fmap_D(),

      .OUT_result_valid_A(),
      .OUT_result_valid_B(),
      .OUT_result_valid_C(),
      .OUT_result_valid_D()
  );

  // ===| [10] CVO Core |=========================================================
  // e_max BF16 encoding: value = 2^(exp - 127), mantissa implicit 1.0.
  //   delayed_emax_32[0] is the 8-bit exponent field from column-0 normalizer.
  //   Packed as BF16: {sign=0, exp=delayed_emax_32[0], mant=7'b0}.
  logic [15:0] cvo_emax_bf16;
  logic        cvo_busy_wire;
  logic        cvo_done_wire;

  assign cvo_emax_bf16 = {1'b0, delayed_emax_32[0], 7'b0};

  CVO_top u_CVO_top (
      .clk    (clk_core),
      .rst_n  (rst_n_core),
      .i_clear(i_clear),

      .IN_uop       (CVO_uop_wire),
      .IN_uop_valid (cvo_op_x64_valid_wire),
      .OUT_uop_ready(),

      // ===| L2 DMA stream — via mem_CVO_stream_bridge inside mem_dispatcher |===
      .IN_data       (cvo_disp_data_wire),
      .IN_data_valid (cvo_disp_valid_wire),
      .OUT_data_ready(cvo_disp_ready_wire),

      .OUT_result      (cvo_result_wire),
      .OUT_result_valid(cvo_result_valid_wire),
      .IN_result_ready (cvo_result_ready_wire),

      .IN_e_max(cvo_emax_bf16),

      .OUT_busy(cvo_busy_wire),
      .OUT_done(cvo_done_wire),
      .OUT_accm()
  );

  // ===| Status |================================================================
  // Aggregated NPU busy/done flags routed to ctrl_npu_frontend IN_enc_stat via
  // the npu_controller_top instance above.
  // Bit 0 : BUSY  (memory FIFO full | CVO engine active | CVO DMA bridge active | STORE active)
  // Bit 1 : DONE  (latched CVO operation or STORE writeback completion)
  logic        npu_done_latched;
  logic        npu_done_event;
  logic [13:0] top_debug_status;
  logic [13:0] top_debug_seen;

  assign npu_done_event = cvo_done_wire | store_done_wire;

  always_ff @(posedge clk_core) begin
    if (!rst_n_core || i_clear) begin
      npu_done_latched <= 1'b0;
    end else begin
      if (GEMM_op_x64_valid_wire || cvo_op_x64_valid_wire) begin
        npu_done_latched <= 1'b0;
      end else if (npu_done_event) begin
        npu_done_latched <= 1'b1;
      end
    end
  end

  logic fmap_broadcast_data_nonzero;
  logic raw_res_data_nonzero;
  logic norm_res_data_nonzero;

  always_comb begin
    fmap_broadcast_data_nonzero = 1'b0;
    raw_res_data_nonzero = 1'b0;
    norm_res_data_nonzero = 1'b0;
    for (int dbg_i = 0; dbg_i < `ARRAY_SIZE_H; dbg_i++) begin
      fmap_broadcast_data_nonzero |= fmap_broadcast_valid & (|fmap_broadcast[dbg_i]);
      raw_res_data_nonzero |= raw_res_sum_valid[dbg_i] & (|raw_res_sum[dbg_i]);
      norm_res_data_nonzero |= norm_res_seq_valid[dbg_i] & (|norm_res_seq[dbg_i]);
    end
  end

  always_ff @(posedge clk_core) begin
    if (!rst_n_core || i_clear) begin
      top_debug_seen <= '0;
    end else begin
      top_debug_seen[13] <= top_debug_seen[13] | M_AXIS_ACP_RESULT.tready;
      top_debug_seen[12] <= top_debug_seen[12] | (packed_res_valid & (|packed_res_data));
      top_debug_seen[11] <= top_debug_seen[11] | (M_CORE_HP1_WEIGHT.tvalid & (|M_CORE_HP1_WEIGHT.tdata));
      top_debug_seen[10] <= top_debug_seen[10] | (M_CORE_HP0_WEIGHT.tvalid & (|M_CORE_HP0_WEIGHT.tdata));
      top_debug_seen[9]  <= top_debug_seen[9]  | fmap_broadcast_data_nonzero;
      top_debug_seen[8]  <= top_debug_seen[8]  | GEMM_op_x64_valid_wire;
      top_debug_seen[7]  <= top_debug_seen[7]  | gemm_global_inst_valid_aligned;
      top_debug_seen[6]  <= top_debug_seen[6]  | raw_res_data_nonzero;
      top_debug_seen[5]  <= top_debug_seen[5]  | norm_res_data_nonzero;
      top_debug_seen[4]  <= top_debug_seen[4]  | (&norm_res_valid_bits);
      top_debug_seen[3]  <= top_debug_seen[3]  | packed_res_ready;
      top_debug_seen[2]  <= top_debug_seen[2]  | packed_res_valid;
      top_debug_seen[1]  <= top_debug_seen[1]  | store_busy_wire;
      top_debug_seen[0]  <= top_debug_seen[0]  | store_done_wire;
    end
  end

  // v36 Stage1 debug map, routed to mmio_npu_stat[15:2].
  // Bits 12/11/10/9/6/5 now report data nonzero observations, not just valid.
  // Bits are sticky "seen since reset/clear" latches so board polling cannot
  // miss one-cycle GEMM/start/result pulses.
  assign top_debug_status = {
    top_debug_seen[13],
    top_debug_seen[12],
    top_debug_seen[11],
    top_debug_seen[10],
    top_debug_seen[9],
    top_debug_seen[8],
    top_debug_seen[7],
    top_debug_seen[6],
    top_debug_seen[5],
    top_debug_seen[4],
    top_debug_seen[3],
    top_debug_seen[2],
    top_debug_seen[1],
    top_debug_seen[0]
  };

  // todo - signal add : acp_is_busy_wire, npu_is_busy_wire, OUT_acp_cmd_valid, OUT_npu_cmd_valid
  assign mmio_npu_stat[0] = fifo_full_wire | cvo_busy_wire | cvo_disp_busy_wire | store_busy_wire;
  assign mmio_npu_stat[1] = npu_done_latched | npu_done_event;
  assign mmio_npu_stat[15:2] = top_debug_status;
  assign mmio_npu_stat[31:16] = mem_debug_status_wire;

endmodule
