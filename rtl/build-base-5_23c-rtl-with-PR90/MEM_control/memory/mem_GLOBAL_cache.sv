// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 pccxai
`timescale 1ns / 1ps
`include "GEMM_Array.svh"
`include "GLOBAL_CONST.svh"
`include "mem_IO.svh"

import isa_pkg::*;

// ===| Module: mem_GLOBAL_cache — L2 cache controller (URAM + ACP/NPU FSMs) |==
// Purpose      : Wrap mem_L2_cache_fmap (URAM) with the ACP DMA state machine
//                and the NPU compute access state machine, plus the ACP CDC
//                bridge (mem_BUFFER). Hides URAM port-A/port-B handshaking
//                from upstream. (Keller "deep module" boundary.)
// Spec ref     : pccx v002 §5.1, §5.4 (port arbitration), §5.5 (CDC).
// Clocks       : Dual-clock — clk_core (URAM, NPU FSM) + clk_axi (ACP-side
//                AXIS). CDC isolated to mem_BUFFER.
// Resets       : rst_n_core / rst_axi_n active-low.
//   Port A — ACP DMA : host DDR4 ↔ L2 via AXI-Stream (CDC via mem_BUFFER).
//   Port B — NPU     : compute engines (GEMM / GEMV / CVO) streaming R/W.
// Arbitration  : Port B is driven externally via IN_npu_* signals; the
//                upstream mem_dispatcher drives IN_npu_direct_* when the CVO
//                bridge owns port B; otherwise the local NPU FSM owns it.
// Latency      : ACP/NPU read = URAM_LATENCY cycles after read issue;
//                tracked via acp_rd_valid_pipe.
// Throughput   : 1 ACP transaction + 1 NPU transaction in flight in parallel.
// Address unit : 128-bit words (address 0 = first 128-bit line).
// Reset state  : both FSMs ST_IDLE-equivalent (acp_is_busy = 0, npu_is_busy = 0).
// Counters     : none.
// Assertions   : (Stage C) acp_ptr never exceeds acp_end_addr; the same for
//                npu_ptr / npu_end_addr.
// ===============================================================================

module mem_GLOBAL_cache (
    input logic clk_core,
    input logic rst_n_core,
    input logic clk_axi,
    input logic rst_axi_n,

    // ===| AXI-Stream ACP (external, AXI clock domain) |========================
    axis_if.slave  S_AXIS_ACP_FMAP,    // feature map in  (128-bit, from PS/DDR4)
    axis_if.master M_AXIS_ACP_RESULT,  // result out       (128-bit, to PS/DDR4)
    axis_if.master M_AXIS_NPU_FMAP,    // L2 -> preprocess fmap stream

    // ===| Port A — ACP DMA control |============================================
    input  logic        IN_acp_write_en,   // 1=write (DDR→L2), 0=read (L2→DDR)
    input  logic [16:0] IN_acp_base_addr,
    input  logic        IN_acp_rx_start,   // start ACP transfer
    input  logic [16:0] IN_acp_end_addr,
    output logic        OUT_acp_is_busy,

    // ===| Port B — NPU compute direct access |==================================
    input  logic        IN_npu_write_en,
    input  logic [16:0] IN_npu_base_addr,
    input  logic        IN_npu_rx_start,
    input  logic [16:0] IN_npu_end_addr,
    output logic        OUT_npu_is_busy,

    // Direct port-B owner: CVO bridge in mem_dispatcher. IN_npu_direct_en
    // holds the local NPU FSM while a bridge op is active.
    input logic         IN_npu_direct_en,
    input logic         IN_npu_direct_valid,
    input logic         IN_npu_direct_we,
    input logic [ 16:0] IN_npu_direct_addr,
    input logic [127:0] IN_npu_direct_wdata,

    input  logic [127:0] IN_npu_wdata,
    output logic [127:0] OUT_npu_rdata,
    output logic [ 15:0] OUT_debug_status
);

  // ===| ACP CDC FIFO (AXI → Core clock) |=======================================
  axis_if #(.DATA_WIDTH(128)) core_acp_rx_bus ();
  axis_if #(.DATA_WIDTH(128)) core_acp_tx_bus ();
  axis_if #(.DATA_WIDTH(128)) S_AXIS_ACP_FMAP_WIRE ();
  axis_if #(.DATA_WIDTH(128)) M_AXIS_ACP_RESULT_WIRE ();
  axis_if #(.DATA_WIDTH(128)) M_AXIS_NPU_FMAP_WIRE ();

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

  assign M_AXIS_NPU_FMAP.tdata        = M_AXIS_NPU_FMAP_WIRE.tdata;
  assign M_AXIS_NPU_FMAP.tvalid       = M_AXIS_NPU_FMAP_WIRE.tvalid;
  assign M_AXIS_NPU_FMAP.tlast        = M_AXIS_NPU_FMAP_WIRE.tlast;
  assign M_AXIS_NPU_FMAP.tkeep        = M_AXIS_NPU_FMAP_WIRE.tkeep;
  assign M_AXIS_NPU_FMAP_WIRE.tready  = M_AXIS_NPU_FMAP.tready;

  mem_BUFFER u_acp_cdc (
      .clk_core         (clk_core),
      .rst_n_core       (rst_n_core),
      .clk_axi          (clk_axi),
      .rst_axi_n        (rst_axi_n),
      .S_AXIS_ACP_FMAP  (S_AXIS_ACP_FMAP_WIRE),
      .M_AXIS_ACP_RESULT(M_AXIS_ACP_RESULT_WIRE),
      .M_CORE_ACP_RX    (core_acp_rx_bus),
      .S_CORE_ACP_TX    (core_acp_tx_bus)
  );

  // ===| Port A — ACP state machine (core clock domain) |=======================
  logic [16:0] acp_ptr;
  logic        acp_write_en;
  logic        acp_is_busy;
  logic [16:0] acp_end_addr;
  logic [16:0] acp_last_addr;
  logic        acp_cmd_pending;
  logic        acp_cmd_write_en;
  logic [16:0] acp_cmd_base_addr;
  logic [16:0] acp_cmd_end_addr;

  localparam int URAM_LATENCY = 7;
  localparam int ACP_TX_Q_DEPTH = 16;
  localparam int ACP_TX_Q_PTR_W = 4;

  // ACP read pipeline: tracks mem_L2_cache_fmap READ_LATENCY.
  logic [URAM_LATENCY-1:0] acp_rd_valid_pipe;
  logic [URAM_LATENCY-1:0] acp_rd_last_pipe;
  logic                    acp_read_fire;
  logic                    acp_on_last_word;
  logic                    acp_tx_q_has_credit;
  logic                    acp_tx_q_push;
  logic                    acp_tx_q_pop;
  logic                    acp_read_drain_busy;
  logic [127:0]            acp_tx_q_data [0:ACP_TX_Q_DEPTH-1];
  logic                    acp_tx_q_last [0:ACP_TX_Q_DEPTH-1];
  logic [ACP_TX_Q_PTR_W-1:0] acp_tx_q_wr_ptr;
  logic [ACP_TX_Q_PTR_W-1:0] acp_tx_q_rd_ptr;
  logic [ACP_TX_Q_PTR_W:0]   acp_tx_q_count;
  logic [ACP_TX_Q_PTR_W:0]   acp_rd_pipe_count;
  logic [ACP_TX_Q_PTR_W:0]   acp_tx_pending_count;
  logic [127:0]              acp_rdata_wire;

  always_comb begin
    acp_rd_pipe_count = '0;
    for (int i = 0; i < URAM_LATENCY; i++) begin
      acp_rd_pipe_count = acp_rd_pipe_count + acp_rd_valid_pipe[i];
    end
  end

  assign acp_tx_pending_count = acp_tx_q_count + acp_rd_pipe_count;
  assign acp_tx_q_has_credit = (acp_tx_pending_count < ACP_TX_Q_DEPTH);
  assign acp_read_fire   = acp_is_busy & ~acp_write_en & acp_tx_q_has_credit;
  assign acp_on_last_word = (acp_ptr >= acp_last_addr);
  assign acp_tx_q_push = acp_rd_valid_pipe[URAM_LATENCY-1];
  assign acp_tx_q_pop = core_acp_tx_bus.tvalid & core_acp_tx_bus.tready;
  assign acp_read_drain_busy = (|acp_rd_valid_pipe) | (acp_tx_q_count != '0);
  assign OUT_acp_is_busy = acp_is_busy | acp_cmd_pending | acp_read_drain_busy;

  always_ff @(posedge clk_core) begin
    if (!rst_n_core) begin
      acp_rd_valid_pipe <= '0;
      acp_rd_last_pipe  <= '0;
    end else begin
      acp_rd_valid_pipe <= {acp_rd_valid_pipe[URAM_LATENCY-2:0], acp_read_fire};
      acp_rd_last_pipe  <= {acp_rd_last_pipe[URAM_LATENCY-2:0], (acp_read_fire && acp_on_last_word)};
    end
  end

  always_ff @(posedge clk_core) begin
    if (!rst_n_core) begin
      acp_tx_q_wr_ptr <= '0;
      acp_tx_q_rd_ptr <= '0;
      acp_tx_q_count  <= '0;
    end else begin
      if (acp_tx_q_push) begin
        acp_tx_q_data[acp_tx_q_wr_ptr] <= acp_rdata_wire;
        acp_tx_q_last[acp_tx_q_wr_ptr] <= acp_rd_last_pipe[URAM_LATENCY-1];
        acp_tx_q_wr_ptr <= acp_tx_q_wr_ptr + 1'b1;
      end

      if (acp_tx_q_pop) begin
        acp_tx_q_rd_ptr <= acp_tx_q_rd_ptr + 1'b1;
      end

      unique case ({acp_tx_q_push, acp_tx_q_pop})
        2'b10: acp_tx_q_count <= acp_tx_q_count + 1'b1;
        2'b01: acp_tx_q_count <= acp_tx_q_count - 1'b1;
        default: acp_tx_q_count <= acp_tx_q_count;
      endcase
    end
  end

  assign core_acp_tx_bus.tvalid = (acp_tx_q_count != '0);
  assign core_acp_tx_bus.tdata  = (acp_tx_q_count != '0) ? acp_tx_q_data[acp_tx_q_rd_ptr] : '0;
  assign core_acp_tx_bus.tkeep  = '1;
  assign core_acp_tx_bus.tlast  = (acp_tx_q_count != '0) ? acp_tx_q_last[acp_tx_q_rd_ptr] : 1'b0;

  logic acp_rx_fire;

  assign core_acp_rx_bus.tready = acp_is_busy & acp_write_en;
  assign acp_rx_fire = core_acp_rx_bus.tvalid & core_acp_rx_bus.tready;

  always_ff @(posedge clk_core) begin
    if (!rst_n_core) begin
      acp_ptr           <= '0;
      acp_end_addr      <= '0;
      acp_last_addr     <= '0;
      acp_is_busy       <= 1'b0;
      acp_write_en      <= 1'b0;
      acp_cmd_pending   <= 1'b0;
      acp_cmd_write_en  <= 1'b0;
      acp_cmd_base_addr <= '0;
      acp_cmd_end_addr  <= '0;
    end else begin
      if (acp_is_busy) begin
        if (acp_write_en) begin
          //if (core_acp_rx_bus.tvalid) begin
          if (acp_rx_fire) begin
            acp_ptr <= acp_ptr + 17'd1;
            if (acp_ptr + 17'd1 >= acp_end_addr) acp_is_busy <= 1'b0;
          end
        end else begin
          if (acp_read_fire) begin
            acp_ptr <= acp_ptr + 17'd1;
            if (acp_ptr + 17'd1 >= acp_end_addr) acp_is_busy <= 1'b0;
          end
        end
      end else if (acp_cmd_pending) begin
        acp_ptr         <= acp_cmd_base_addr;
        acp_end_addr    <= acp_cmd_end_addr;
        acp_last_addr   <= acp_cmd_end_addr - 17'd1;
        acp_is_busy     <= 1'b1;
        acp_write_en    <= acp_cmd_write_en;
        acp_cmd_pending <= 1'b0;
      end else if (IN_acp_rx_start) begin
        acp_cmd_base_addr <= IN_acp_base_addr;
        acp_cmd_end_addr  <= IN_acp_end_addr;
        acp_cmd_write_en  <= IN_acp_write_en;
        acp_cmd_pending   <= 1'b1;
      end
    end
  end

  // ===| Port B — NPU state machine |============================================
  logic [            16:0] npu_ptr;
  logic                    npu_write_en;
  logic                    npu_is_busy;
  logic [            16:0] npu_end_addr;
  logic [            16:0] npu_last_addr;
  logic [URAM_LATENCY-1:0] npu_rd_valid_pipe;
  logic [URAM_LATENCY-1:0] npu_rd_last_pipe;
  logic                    npu_read_fire;
  logic                    npu_write_fire;
  logic                    npu_on_last_word;
  logic                    npu_fmap_ready_q;
  logic                    npu_direct_active;
  logic                    npu_direct_cmd;
  logic                    npu_direct_owner_q;
  logic                    npu_direct_cmd_q;
  logic                    npu_direct_we_q;
  logic [            16:0] npu_direct_addr_q;
  logic [           127:0] npu_direct_wdata_q;
  logic                    l2_npu_we;
  logic [            16:0] l2_npu_addr;
  logic [           127:0] l2_npu_wdata;

  assign OUT_npu_is_busy = npu_is_busy;
  assign npu_direct_active = npu_direct_owner_q | npu_direct_cmd_q;
  assign npu_direct_cmd = npu_direct_cmd_q;
  assign npu_read_fire = npu_is_busy & ~npu_write_en & npu_fmap_ready_q & ~npu_direct_active;
  assign npu_write_fire = npu_is_busy & npu_write_en & ~npu_direct_active;
  assign npu_on_last_word = (npu_ptr >= npu_last_addr);

  assign M_AXIS_NPU_FMAP_WIRE.tdata = OUT_npu_rdata;
  assign M_AXIS_NPU_FMAP_WIRE.tvalid = npu_rd_valid_pipe[URAM_LATENCY-1];
  assign M_AXIS_NPU_FMAP_WIRE.tlast = npu_rd_last_pipe[URAM_LATENCY-1];
  assign M_AXIS_NPU_FMAP_WIRE.tkeep = '1;

  always_ff @(posedge clk_core) begin
    if (!rst_n_core) npu_fmap_ready_q <= 1'b0;
    else npu_fmap_ready_q <= M_AXIS_NPU_FMAP_WIRE.tready;
  end

  always_ff @(posedge clk_core) begin
    if (!rst_n_core) begin
      npu_rd_valid_pipe <= '0;
      npu_rd_last_pipe  <= '0;
    end else begin
      npu_rd_valid_pipe <= {npu_rd_valid_pipe[URAM_LATENCY-2:0], npu_read_fire};
      npu_rd_last_pipe <= {npu_rd_last_pipe[URAM_LATENCY-2:0], (npu_read_fire && npu_on_last_word)};
    end
  end

  // Stage CVO direct commands next to the L2 port-B mux so the bridge FSM valid
  // pulse does not fan out directly into the URAM write-control net.
  always_ff @(posedge clk_core) begin
    if (!rst_n_core) begin
      npu_direct_cmd_q   <= 1'b0;
      npu_direct_owner_q <= 1'b0;
      npu_direct_we_q    <= 1'b0;
      npu_direct_addr_q  <= '0;
      npu_direct_wdata_q <= '0;
    end else begin
      npu_direct_cmd_q   <= IN_npu_direct_valid;
      npu_direct_owner_q <= IN_npu_direct_en;
      npu_direct_we_q    <= IN_npu_direct_we;
      npu_direct_addr_q  <= IN_npu_direct_addr;
      npu_direct_wdata_q <= IN_npu_direct_wdata;
    end
  end

  always_ff @(posedge clk_core) begin
    if (!rst_n_core) begin
      npu_ptr       <= '0;
      npu_end_addr  <= '0;
      npu_last_addr <= '0;
      npu_is_busy   <= 1'b0;
      npu_write_en  <= 1'b0;
    end else begin
      if (npu_is_busy) begin
        if (npu_write_fire || npu_read_fire) begin
          npu_ptr <= npu_ptr + 17'd1;
          if (npu_on_last_word) npu_is_busy <= 1'b0;
        end
      end else if (IN_npu_rx_start) begin
        npu_ptr       <= IN_npu_base_addr;
        npu_end_addr  <= IN_npu_end_addr;
        npu_last_addr <= IN_npu_end_addr - 17'd1;
        npu_is_busy   <= 1'b1;
        npu_write_en  <= IN_npu_write_en;
      end
    end
  end

  always_comb begin
    l2_npu_we    = npu_write_fire;
    l2_npu_addr  = npu_ptr;
    l2_npu_wdata = IN_npu_wdata;

    if (npu_direct_cmd) begin
      l2_npu_we    = npu_direct_we_q;
      l2_npu_addr  = npu_direct_addr_q;
      l2_npu_wdata = npu_direct_wdata_q;
    end
  end

  // ===| L2 URAM (port B shared between ACP read-out and NPU compute) |=========
  // Port A → ACP DMA (write when host→L2, read when L2→host)
  // Port B → NPU compute (fmap broadcast, CVO streaming)
  mem_L2_cache_fmap #(
      .Depth(114688)
  ) u_l2_uram (
      .clk_core  (clk_core),
      .rst_n_core(rst_n_core),

	      // Keep URAM ports enabled; write strobes and valid pipes gate effects.
	      // This avoids a 400 MHz path from read-valid drain state into URAM EN.
	      .IN_acp_en(1'b1),
      //.IN_acp_we   (acp_write_en & core_acp_rx_bus.tvalid),
      .IN_acp_we(acp_rx_fire),
      .IN_acp_addr(acp_ptr),
      .IN_acp_wdata(core_acp_rx_bus.tdata),
      .OUT_acp_rdata(acp_rdata_wire),

	      // Port B — NPU compute
	      .IN_npu_en    (1'b1),
      .IN_npu_we    (l2_npu_we),
      .IN_npu_addr  (l2_npu_addr),
      .IN_npu_wdata (l2_npu_wdata),
      .OUT_npu_rdata(OUT_npu_rdata)
  );

  assign OUT_debug_status = {
    npu_direct_active,
    npu_direct_cmd_q,
    IN_npu_direct_en,
    IN_npu_direct_valid,
    IN_npu_direct_we,
    npu_is_busy,
    acp_is_busy,
    acp_cmd_pending,
    IN_acp_rx_start,
    acp_write_en,
    acp_rx_fire,
    acp_read_fire,
    core_acp_rx_bus.tvalid,
    core_acp_rx_bus.tready,
    core_acp_tx_bus.tvalid,
    core_acp_tx_bus.tready
  };

endmodule
