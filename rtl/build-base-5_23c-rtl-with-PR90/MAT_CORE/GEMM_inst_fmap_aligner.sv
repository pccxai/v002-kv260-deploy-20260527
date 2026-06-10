// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 pccxai
`timescale 1ns / 1ps

// ===| Module: GEMM_inst_fmap_aligner |=========================================
// Purpose:
//   Align the registered GEMM instruction flags with the first fmap broadcast
//   cycle that reaches the systolic stagger line.
//
// Why:
//   Global_Scheduler registers OUT_GEMM_uop one clock after
//   IN_GEMM_op_x64_valid. The fmap broadcast starts later, after preprocess_fmap
//   receives and caches the L2 stream. Driving GEMM_op_x64_valid directly into
//   GEMM_systolic_top can therefore present stale flags and a valid pulse long
//   before fmap_valid is high.
//
// Contract:
//   - i_gemm_op_valid marks that a GEMM uop will be visible on the next cycle.
//   - i_gemm_inst_registered is sampled one cycle later.
//   - o_global_inst_valid pulses once in the first i_fmap_valid window.
// ===============================================================================
module GEMM_inst_fmap_aligner (
    input logic clk,
    input logic rst_n,
    input logic i_clear,

    input logic       i_gemm_op_valid,
    input logic [2:0] i_gemm_inst_registered,
    input logic       i_fmap_valid,

    output logic [2:0] o_global_inst,
    output logic       o_global_inst_valid
);

  logic       capture_pending;
  logic       inst_pending;
  logic [2:0] inst_latched;

  assign o_global_inst = inst_latched;
  assign o_global_inst_valid = inst_pending & i_fmap_valid;

  always_ff @(posedge clk) begin
    if (!rst_n || i_clear) begin
      capture_pending <= 1'b0;
      inst_pending    <= 1'b0;
      inst_latched    <= 3'b000;
    end else begin
      if (i_gemm_op_valid) begin
        capture_pending <= 1'b1;
      end else if (capture_pending) begin
        capture_pending <= 1'b0;
      end

      if (capture_pending) begin
        inst_latched <= i_gemm_inst_registered;
        inst_pending <= 1'b1;
      end else if (inst_pending && i_fmap_valid) begin
        inst_pending <= 1'b0;
      end
    end
  end

endmodule
