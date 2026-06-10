// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 pccxai
`include "GLOBAL_CONST.svh"
`timescale 1ns / 1ps
`include "GEMM_Array.svh"
`include "npu_interfaces.svh"

// ===| Module: preprocess_fmap — BF16 → fixed-point fmap front-end |=============
// Purpose      : Convert ACP-streamed BF16 fmap into the fixed-point mantissa
//                array consumed by the systolic, GEMV, and CVO engines, plus
//                cache the per-block e_max for downstream re-normalisation.
// Spec ref     : pccx v002 §2.2 (PREPROCESS), §5.2 (fmap cache).
// Clock        : clk @ 400 MHz.
// Reset        : rst_n active-low; i_clear synchronous soft-clear (clears
//                e_max cache pointers and SRAM write address).
// Pipeline     : (1) 256-bit AXI-Stream FIFO  → (2) e_max parse / cache
//                                              → (3) BF16-fixed shifter
//                                              → (4) L1 SRAM (fmap_cache).
// Latency      : ~ shifter pipeline depth + 1 SRAM cycle (see fmap_cache).
// Throughput   : 32 fixed-point lanes broadcast per cycle once rd_start fires.
// Handshake    : Input AXIS — backpressured by fmap_shifter_ready.
//                Output broadcast — synchronous to o_fmap_valid; consumers
//                must accept unconditionally during the steady-state run.
// Reset state  : fmap_word_toggle = 0, emax_wr_addr = 0, sram_wr_addr = 0,
//                emax_group_valid = 0, pending read request = 0.
// Counters     : none. (Stage D: fmap_words_in, broadcast_pulses, stall_cycles.)
// Assertions   : (Stage C) S_AXIS_ACP_FMAP backpressure stability; emax_wr_addr
//                bounded by FMAP_CACHE_DEPTH.
// Notes        : Two 128-bit ACP beats are merged into one 256-bit FIFO word
//                here so the 16-lane shifter and 2048-deep fmap cache see the
//                same element geometry as the 128-bit L2 word-count contract.
// ===============================================================================
module preprocess_fmap #(
    parameter fmap_width = `DEVICE_ACP_WIDTH_BIT
) (
    input logic clk,
    input logic rst_n,
    input logic i_clear,

    // AXI4-Stream Interfaces from ACP
    axis_if.slave S_AXIS_ACP_FMAP,  // ACP (128-bit)

    // Control from Brain
    input logic i_rd_start,




    // Output to Branch Engines (Systolic / GEMV / CVO)
    output logic [`FIXED_MANT_WIDTH-1:0] o_fmap_broadcast[0:`ARRAY_SIZE_H-1],
    output logic                         o_fmap_valid,

    output logic [`BF16_EXP_WIDTH-1:0] o_cached_emax[0:`ARRAY_SIZE_H-1]
);

  // ===| Bridge & Alignment: 128-bit L2 stream -> 256-bit preprocess word |====
  logic [127:0] fmap_merge_low;
  logic         fmap_merge_half_valid;
  logic         fmap_merge_half_last;
  logic [255:0] fmap_merge_data;
  logic         fmap_merge_valid;
  logic         fmap_merge_ready;
  logic         fmap_merge_fire;

  logic [255:0] fmap_fifo_data;
  logic         fmap_fifo_valid;
  logic         fmap_fifo_ready;

  assign fmap_merge_data  = fmap_merge_half_last ? {128'd0, fmap_merge_low}
                                                 : {S_AXIS_ACP_FMAP.tdata, fmap_merge_low};
  assign fmap_merge_valid = fmap_merge_half_valid &&
                            (fmap_merge_half_last || S_AXIS_ACP_FMAP.tvalid);
  assign fmap_merge_fire  = fmap_merge_valid && fmap_merge_ready;

  assign S_AXIS_ACP_FMAP.tready = !fmap_merge_half_valid ||
                                  (!fmap_merge_half_last && fmap_merge_ready);

  always_ff @(posedge clk) begin
    if (!rst_n || i_clear || i_rd_start) begin
      fmap_merge_low        <= '0;
      fmap_merge_half_valid <= 1'b0;
      fmap_merge_half_last  <= 1'b0;
    end else if (S_AXIS_ACP_FMAP.tvalid && S_AXIS_ACP_FMAP.tready) begin
      if (!fmap_merge_half_valid) begin
        fmap_merge_low        <= S_AXIS_ACP_FMAP.tdata;
        fmap_merge_half_valid <= 1'b1;
        fmap_merge_half_last  <= S_AXIS_ACP_FMAP.tlast;
      end else begin
        fmap_merge_half_valid <= 1'b0;
        fmap_merge_half_last  <= 1'b0;
      end
    end else if (fmap_merge_fire && fmap_merge_half_last) begin
      fmap_merge_half_valid <= 1'b0;
      fmap_merge_half_last  <= 1'b0;
    end
  end

  xpm_fifo_axis #(
      .FIFO_DEPTH(`DEVICE_XPM_FIFO_DEPTH),
      .TDATA_WIDTH(256),
      .FIFO_MEMORY_TYPE("block"),
      .CLOCKING_MODE("common_clock")
  ) u_fmap_fifo (
      .s_aclk(clk),
      .m_aclk(clk),
      .s_aresetn(rst_n),
      .s_axis_tdata(fmap_merge_data),
      .s_axis_tvalid(fmap_merge_valid),
      .s_axis_tready(fmap_merge_ready),
      .m_axis_tdata(fmap_fifo_data),
      .m_axis_tvalid(fmap_fifo_valid),
      .m_axis_tready(fmap_fifo_ready)
  );

  // ===| e_max parsing & cache logic |=======
  logic [`BF16_EXP_WIDTH-1:0] active_emax[0:`ARRAY_SIZE_H-1];
  logic fmap_word_toggle;
  logic emax_group_valid;

  always_ff @(posedge clk) begin
    if (!rst_n || i_clear || i_rd_start) begin
      fmap_word_toggle <= 1'b0;
      emax_group_valid <= 1'b0;
    end else if (fmap_fifo_valid && fmap_fifo_ready) begin
      fmap_word_toggle <= ~fmap_word_toggle;
      for (int k = 0; k < 16; k++) begin
        if (fmap_word_toggle == 1'b0) active_emax[k] <= fmap_fifo_data[(k*16)+7+:8];
        else active_emax[k+16] <= fmap_fifo_data[(k*16)+7+:8];
      end
      emax_group_valid <= (fmap_word_toggle == 1'b1);
    end else begin
      emax_group_valid <= 1'b0;
    end
  end

  localparam int EMAX_CACHE_WIDTH  = `ARRAY_SIZE_H * `BF16_EXP_WIDTH;
  localparam int EMAX_CACHE_DEPTH  = `FMAP_CACHE_DEPTH / `ARRAY_SIZE_H;
  localparam int EMAX_CACHE_ADDR_W = $clog2(EMAX_CACHE_DEPTH);
  logic [EMAX_CACHE_WIDTH-1:0] emax_active_pack;
  logic [EMAX_CACHE_WIDTH-1:0] emax_cache_rdata;
  logic [EMAX_CACHE_WIDTH-1:0] emax_cache_mem[0:EMAX_CACHE_DEPTH-1];
  logic [EMAX_CACHE_ADDR_W-1:0] emax_wr_addr, emax_rd_addr;
  logic       fmap_sram_rd_start;
  logic [4:0] emax_rd_elem_phase;

  always_comb begin
    for (int i = 0; i < `ARRAY_SIZE_H; i++) begin
      emax_active_pack[i*`BF16_EXP_WIDTH+:`BF16_EXP_WIDTH] = active_emax[i];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n || i_clear || i_rd_start) begin
      emax_wr_addr <= 0;
    end else if (emax_group_valid) begin
      emax_cache_mem[emax_wr_addr] <= emax_active_pack;
      emax_wr_addr <= emax_wr_addr + 1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n || i_clear) begin
      emax_rd_addr <= 0;
    end else if (fmap_sram_rd_start) begin
      emax_rd_addr <= 0;
    end else if (o_fmap_valid) begin
      if (emax_rd_elem_phase == 5'd31) emax_rd_addr <= emax_rd_addr + 1;
    end
    emax_cache_rdata <= emax_cache_mem[emax_rd_addr];
  end

  always_comb begin
    for (int i = 0; i < `ARRAY_SIZE_H; i++) begin
      o_cached_emax[i] = (!rst_n || i_clear)
        ? '0
        : emax_cache_rdata[i*`BF16_EXP_WIDTH+:`BF16_EXP_WIDTH];
    end
  end

  // ===| Mantissa Shifter & SRAM Cache |=======
  logic [431:0] fixed_fmap;
  logic         fixed_fmap_valid;
  logic         fmap_shifter_ready;

  preprocess_bf16_fixed_pipeline u_fmap_shifter (
      .clk(clk),
      .rst_n(rst_n),
      .s_axis_tdata(fmap_fifo_data),
      .s_axis_tvalid(fmap_fifo_valid),
      .s_axis_tready(fmap_shifter_ready),
      .m_axis_tdata(fixed_fmap),
      .m_axis_tvalid(fixed_fmap_valid),
      .m_axis_tready(1'b1)
  );
  assign fmap_fifo_ready = fmap_shifter_ready;

  localparam int FMAP_WRITE_COUNT = `FMAP_CACHE_DEPTH / 16;
  localparam logic [6:0] FMAP_WRITE_LAST_ADDR = 7'(FMAP_WRITE_COUNT - 1);

  logic [6:0] sram_wr_addr;
  logic       fmap_cache_filled;
  logic       fmap_rd_request_pending;

  assign fmap_sram_rd_start = fmap_rd_request_pending && fmap_cache_filled;

  always_ff @(posedge clk) begin
    if (!rst_n || i_clear) begin
      sram_wr_addr            <= 0;
      fmap_cache_filled       <= 1'b0;
      fmap_rd_request_pending <= 1'b0;
    end else begin
      if (i_rd_start) begin
        sram_wr_addr            <= 0;
        fmap_cache_filled       <= 1'b0;
        fmap_rd_request_pending <= 1'b1;
      end else begin
        if (fixed_fmap_valid) begin
          sram_wr_addr <= sram_wr_addr + 1;
          if (sram_wr_addr == FMAP_WRITE_LAST_ADDR) fmap_cache_filled <= 1'b1;
        end
        if (fmap_sram_rd_start) fmap_rd_request_pending <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n || i_clear || fmap_sram_rd_start) begin
      emax_rd_elem_phase <= 5'd0;
    end else if (o_fmap_valid) begin
      emax_rd_elem_phase <= emax_rd_elem_phase + 1;
    end
  end

  fmap_cache #(
      .DATA_WIDTH(`FIXED_MANT_WIDTH),
      .WRITE_LANES(16),
      .CACHE_DEPTH(`FMAP_CACHE_DEPTH),
      .LANES(`ARRAY_SIZE_H)
  ) u_fmap_sram (
      .clk(clk),
      .rst_n(rst_n),
      .wr_data(fixed_fmap),
      .wr_valid(fixed_fmap_valid),
      .wr_addr(sram_wr_addr),
      .wr_en(1'b1),
      .rd_start(fmap_sram_rd_start),
      .rd_data_broadcast(o_fmap_broadcast),
      .rd_valid(o_fmap_valid)
  );

endmodule
