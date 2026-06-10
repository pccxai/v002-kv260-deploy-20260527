// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 pccxai
`timescale 1ns / 1ps
`include "GEMM_Array.svh"
`include "GLOBAL_CONST.svh"
`include "npu_interfaces.svh"

// ===| Module: mem_BUFFER — ACP CDC FIFO pair (RX/TX) |=========================
// Purpose      : Tiny BRAM CDC FIFOs that decouple the AXI clock domain
//                (250 MHz, ACP) from the core clock domain (400 MHz).
//                Bulk fmap storage lives in the L2 URAM cache, so these
//                CDC FIFOs are intentionally TINY (BRAM_FIFO_DEPTH = 32).
// Spec ref     : pccx v002 §5.5 (ACP CDC), §6 (KV260 SoC).
// Clocks       : clk_core (M-side RX, S-side TX) + clk_axi (S-side RX,
//                M-side TX). Independent_clock CDC.
// Resets       : rst_n_core / rst_axi_n active-low — applied to their
//                respective clock domains by xpm_fifo_axis.
// Topology     : 2 × xpm_fifo_axis @ 128-bit, depth 32, BRAM-backed.
// Latency      : Gray-code pointer sync ≈ 2-3 destination clocks.
// Backpressure : Standard AXI4-Stream tvalid/tready propagation.
// Reset state  : Both FIFOs cleared.
// Counters     : none.
// Assertions   : (Stage C) — handled inside xpm_fifo_axis (no over/underflow).
// ===============================================================================
module mem_BUFFER (
    // ===| Clock & Reset |======================================
    input logic clk_core,  // 400MHz
    input logic rst_n_core,
    input logic clk_axi,  // 250MHz
    input logic rst_axi_n,

    // ===| ACP Ports (FMAP/KV) |================================
    axis_if.slave  S_AXIS_ACP_FMAP,   // [RX] Data from DDR4 to NPU
    axis_if.master M_AXIS_ACP_RESULT, // [TX] Data from NPU to DDR4

    axis_if.master M_CORE_ACP_RX,  // [RX] Converted to 400MHz Core
    axis_if.slave  S_CORE_ACP_TX   // [TX] Coming from 400MHz Core
);

  //fine Tiny Depth for BRAM CDC
  localparam int BRAM_FIFO_DEPTH = 32;
  localparam int CDC_PAYLOAD_W = 145;
  localparam int FIFO_COUNT_W = 6;

  logic [127:0] s_acp_fmap_tdata;
  logic         s_acp_fmap_tvalid;
  logic         s_acp_fmap_tready;
  logic [15:0]  s_acp_fmap_tkeep;
  logic         s_acp_fmap_tlast;
  logic [127:0] rx_slice_tdata;
  logic         rx_slice_tvalid;
  logic         rx_slice_present;
  logic         rx_slice_tready;
  logic [15:0]  rx_slice_tkeep;
  logic         rx_slice_tlast;
  logic         rx_slice_pop;

  logic [127:0] m_acp_result_tdata;
  logic         m_acp_result_tvalid;
  logic         m_acp_result_tready;
  logic [15:0]  m_acp_result_tkeep;
  logic         m_acp_result_tlast;
  logic [127:0] tx_axi_hold_tdata;
  logic         tx_axi_hold_tvalid;
  logic [15:0]  tx_axi_hold_tkeep;
  logic         tx_axi_hold_tlast;
  logic         tx_axi_load;

  logic [127:0] m_core_acp_rx_tdata;
  logic         m_core_acp_rx_tvalid;
  logic         m_core_acp_rx_tready;
  logic [15:0]  m_core_acp_rx_tkeep;
  logic         m_core_acp_rx_tlast;
  logic [127:0] rx_core_hold_tdata;
  logic         rx_core_hold_tvalid;
  logic [15:0]  rx_core_hold_tkeep;
  logic         rx_core_hold_tlast;
  logic         rx_core_load;

  logic [127:0] s_core_acp_tx_tdata;
  logic         s_core_acp_tx_tvalid;
  logic         s_core_acp_tx_tready;
  logic [15:0]  s_core_acp_tx_tkeep;
  logic         s_core_acp_tx_tlast;

  logic                  fifo_rst;
  logic [CDC_PAYLOAD_W-1:0] rx_fifo_din;
  logic [CDC_PAYLOAD_W-1:0] rx_fifo_dout;
  logic                  rx_fifo_full;
  logic                  rx_fifo_empty;
  logic                  rx_fifo_wr_en;
  logic                  rx_fifo_rd_en;
  logic                  rx_fifo_wr_rst_busy;
  logic                  rx_fifo_rd_rst_busy;
  logic                  rx_fifo_wr_ack;
  logic                  rx_fifo_overflow;
  logic                  rx_fifo_underflow;
  logic                  rx_fifo_data_valid;
  logic [FIFO_COUNT_W-1:0] rx_fifo_wr_data_count;
  logic [FIFO_COUNT_W-1:0] rx_fifo_rd_data_count;

  logic [CDC_PAYLOAD_W-1:0] tx_fifo_din;
  logic [CDC_PAYLOAD_W-1:0] tx_fifo_dout;
  logic                  tx_fifo_full;
  logic                  tx_fifo_empty;
  logic                  tx_fifo_wr_en;
  logic                  tx_fifo_rd_en;
  logic                  tx_fifo_wr_rst_busy;
  logic                  tx_fifo_rd_rst_busy;
  logic                  tx_fifo_wr_ack;
  logic                  tx_fifo_overflow;
  logic                  tx_fifo_underflow;
  logic                  tx_fifo_data_valid;
  logic [FIFO_COUNT_W-1:0] tx_fifo_wr_data_count;
  logic [FIFO_COUNT_W-1:0] tx_fifo_rd_data_count;

  assign s_acp_fmap_tdata       = S_AXIS_ACP_FMAP.tdata;
  assign s_acp_fmap_tvalid      = S_AXIS_ACP_FMAP.tvalid;
  assign s_acp_fmap_tkeep       = S_AXIS_ACP_FMAP.tkeep;
  assign s_acp_fmap_tlast       = S_AXIS_ACP_FMAP.tlast;
  assign rx_slice_pop           = rx_slice_tvalid & rx_slice_present & rx_slice_tready;
  assign s_acp_fmap_tready      = !rx_slice_tvalid || rx_slice_pop;
  assign S_AXIS_ACP_FMAP.tready = s_acp_fmap_tready;

  assign M_AXIS_ACP_RESULT.tdata  = m_acp_result_tdata;
  assign M_AXIS_ACP_RESULT.tvalid = m_acp_result_tvalid;
  assign M_AXIS_ACP_RESULT.tkeep  = m_acp_result_tkeep;
  assign M_AXIS_ACP_RESULT.tlast  = m_acp_result_tlast;
  assign m_acp_result_tready      = M_AXIS_ACP_RESULT.tready;

  assign M_CORE_ACP_RX.tdata   = m_core_acp_rx_tdata;
  assign M_CORE_ACP_RX.tvalid  = m_core_acp_rx_tvalid;
  assign M_CORE_ACP_RX.tkeep   = m_core_acp_rx_tkeep;
  assign M_CORE_ACP_RX.tlast   = m_core_acp_rx_tlast;
  assign m_core_acp_rx_tready  = M_CORE_ACP_RX.tready;

  assign s_core_acp_tx_tdata   = S_CORE_ACP_TX.tdata;
  assign s_core_acp_tx_tvalid  = S_CORE_ACP_TX.tvalid;
  assign s_core_acp_tx_tkeep   = S_CORE_ACP_TX.tkeep;
  assign s_core_acp_tx_tlast   = S_CORE_ACP_TX.tlast;
  assign S_CORE_ACP_TX.tready  = s_core_acp_tx_tready;

  assign fifo_rst = !rst_axi_n || !rst_n_core;

  always_ff @(posedge clk_axi) begin
    if (!rst_axi_n) begin
      rx_slice_tvalid <= 1'b0;
      rx_slice_present <= 1'b0;
      rx_slice_tdata  <= '0;
      rx_slice_tkeep  <= '0;
      rx_slice_tlast  <= 1'b0;
    end else if (!rx_slice_tvalid || rx_slice_pop) begin
      if (s_acp_fmap_tvalid) begin
        rx_slice_tvalid <= 1'b1;
        rx_slice_present <= 1'b0;
        rx_slice_tdata <= s_acp_fmap_tdata;
        rx_slice_tkeep <= s_acp_fmap_tkeep;
        rx_slice_tlast <= s_acp_fmap_tlast;
      end else begin
        rx_slice_tvalid <= 1'b0;
        rx_slice_present <= 1'b0;
      end
    end else if (!rx_slice_present) begin
      rx_slice_present <= 1'b1;
    end
  end

  // [1] ACP RX FIFO (CDC only: AXI -> Core)
  // Pack AXIS sideband explicitly; this avoids nested interface/packet-FIFO
  // ambiguity at the full NPU wrapper boundary.
  assign rx_slice_tready = !rx_fifo_full && !rx_fifo_wr_rst_busy;
  assign rx_fifo_wr_en = rx_slice_pop;
  assign rx_core_load = (!rx_core_hold_tvalid || m_core_acp_rx_tready) &&
                        !rx_fifo_empty && !rx_fifo_rd_rst_busy;
  assign rx_fifo_rd_en = rx_core_load;
  assign rx_fifo_din = {rx_slice_tlast, rx_slice_tkeep, rx_slice_tdata};
  assign m_core_acp_rx_tdata  = rx_core_hold_tdata;
  assign m_core_acp_rx_tvalid = rx_core_hold_tvalid;
  assign m_core_acp_rx_tkeep  = rx_core_hold_tkeep;
  assign m_core_acp_rx_tlast  = rx_core_hold_tlast;

  always_ff @(posedge clk_core) begin
    if (!rst_n_core) begin
      rx_core_hold_tvalid <= 1'b0;
      rx_core_hold_tdata  <= '0;
      rx_core_hold_tkeep  <= '0;
      rx_core_hold_tlast  <= 1'b0;
    end else if (!rx_core_hold_tvalid || m_core_acp_rx_tready) begin
      if (rx_core_load) begin
        {rx_core_hold_tlast, rx_core_hold_tkeep, rx_core_hold_tdata} <= rx_fifo_dout;
        rx_core_hold_tvalid <= 1'b1;
      end else begin
        rx_core_hold_tvalid <= 1'b0;
      end
    end
  end

  xpm_fifo_async #(
      .FIFO_MEMORY_TYPE("block"),
      .ECC_MODE("no_ecc"),
      .RELATED_CLOCKS(0),
      .FIFO_WRITE_DEPTH(BRAM_FIFO_DEPTH),
      .WRITE_DATA_WIDTH(CDC_PAYLOAD_W),
      .WR_DATA_COUNT_WIDTH(FIFO_COUNT_W),
      .PROG_FULL_THRESH(8),
      .FULL_RESET_VALUE(0),
      .READ_MODE("fwft"),
      .FIFO_READ_LATENCY(0),
      .READ_DATA_WIDTH(CDC_PAYLOAD_W),
      .RD_DATA_COUNT_WIDTH(FIFO_COUNT_W),
      .PROG_EMPTY_THRESH(8),
      .DOUT_RESET_VALUE("0"),
      .CDC_SYNC_STAGES(2),
      .WAKEUP_TIME(0)
  ) u_acp_rx_fifo (
      .sleep(1'b0),
      .rst(fifo_rst),
      .wr_clk(clk_axi),
      .wr_en(rx_fifo_wr_en),
      .din(rx_fifo_din),
      .full(rx_fifo_full),
      .prog_full(),
      .wr_data_count(rx_fifo_wr_data_count),
      .overflow(rx_fifo_overflow),
      .wr_rst_busy(rx_fifo_wr_rst_busy),
      .almost_full(),
      .wr_ack(rx_fifo_wr_ack),
      .rd_clk(clk_core),
      .rd_en(rx_fifo_rd_en),
      .dout(rx_fifo_dout),
      .empty(rx_fifo_empty),
      .prog_empty(),
      .rd_data_count(rx_fifo_rd_data_count),
      .underflow(rx_fifo_underflow),
      .rd_rst_busy(rx_fifo_rd_rst_busy),
      .almost_empty(),
      .data_valid(rx_fifo_data_valid),
      .injectsbiterr(1'b0),
      .injectdbiterr(1'b0),
      .sbiterr(),
      .dbiterr()
  );

  // [2] ACP TX FIFO (CDC only: Core -> AXI)
  assign s_core_acp_tx_tready = !tx_fifo_full && !tx_fifo_wr_rst_busy;
  assign tx_fifo_wr_en = s_core_acp_tx_tvalid && s_core_acp_tx_tready;
  assign tx_axi_load = (!tx_axi_hold_tvalid || m_acp_result_tready) &&
                       !tx_fifo_empty && !tx_fifo_rd_rst_busy;
  assign tx_fifo_rd_en = tx_axi_load;
  assign tx_fifo_din = {s_core_acp_tx_tlast, s_core_acp_tx_tkeep, s_core_acp_tx_tdata};
  assign m_acp_result_tdata  = tx_axi_hold_tdata;
  assign m_acp_result_tvalid = tx_axi_hold_tvalid;
  assign m_acp_result_tkeep  = tx_axi_hold_tkeep;
  assign m_acp_result_tlast  = tx_axi_hold_tlast;

  always_ff @(posedge clk_axi) begin
    if (!rst_axi_n) begin
      tx_axi_hold_tvalid <= 1'b0;
      tx_axi_hold_tdata  <= '0;
      tx_axi_hold_tkeep  <= '0;
      tx_axi_hold_tlast  <= 1'b0;
    end else if (!tx_axi_hold_tvalid || m_acp_result_tready) begin
      if (tx_axi_load) begin
        {tx_axi_hold_tlast, tx_axi_hold_tkeep, tx_axi_hold_tdata} <= tx_fifo_dout;
        tx_axi_hold_tvalid <= 1'b1;
      end else begin
        tx_axi_hold_tvalid <= 1'b0;
      end
    end
  end

  xpm_fifo_async #(
      .FIFO_MEMORY_TYPE("block"),
      .ECC_MODE("no_ecc"),
      .RELATED_CLOCKS(0),
      .FIFO_WRITE_DEPTH(BRAM_FIFO_DEPTH),
      .WRITE_DATA_WIDTH(CDC_PAYLOAD_W),
      .WR_DATA_COUNT_WIDTH(FIFO_COUNT_W),
      .PROG_FULL_THRESH(8),
      .FULL_RESET_VALUE(0),
      .READ_MODE("fwft"),
      .FIFO_READ_LATENCY(0),
      .READ_DATA_WIDTH(CDC_PAYLOAD_W),
      .RD_DATA_COUNT_WIDTH(FIFO_COUNT_W),
      .PROG_EMPTY_THRESH(8),
      .DOUT_RESET_VALUE("0"),
      .CDC_SYNC_STAGES(2),
      .WAKEUP_TIME(0)
  ) u_acp_tx_fifo (
      .sleep(1'b0),
      .rst(fifo_rst),
      .wr_clk(clk_core),
      .wr_en(tx_fifo_wr_en),
      .din(tx_fifo_din),
      .full(tx_fifo_full),
      .prog_full(),
      .wr_data_count(tx_fifo_wr_data_count),
      .overflow(tx_fifo_overflow),
      .wr_rst_busy(tx_fifo_wr_rst_busy),
      .almost_full(),
      .wr_ack(tx_fifo_wr_ack),
      .rd_clk(clk_axi),
      .rd_en(tx_fifo_rd_en),
      .dout(tx_fifo_dout),
      .empty(tx_fifo_empty),
      .prog_empty(),
      .rd_data_count(tx_fifo_rd_data_count),
      .underflow(tx_fifo_underflow),
      .rd_rst_busy(tx_fifo_rd_rst_busy),
      .almost_empty(),
      .data_valid(tx_fifo_data_valid),
      .injectsbiterr(1'b0),
      .injectdbiterr(1'b0),
      .sbiterr(),
      .dbiterr()
  );

endmodule
