`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"
`include "GEMM_Array.svh"
`include "npu_interfaces.svh"

module xpm_fifo_axis #(
    parameter int FIFO_DEPTH = 16,
    parameter int TDATA_WIDTH = 256,
    parameter string FIFO_MEMORY_TYPE = "auto",
    parameter string CLOCKING_MODE = "common_clock"
) (
    input  logic                  s_aclk,
    input  logic                  m_aclk,
    input  logic                  s_aresetn,
    input  logic [TDATA_WIDTH-1:0] s_axis_tdata,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    output logic [TDATA_WIDTH-1:0] m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready
);
  assign s_axis_tready = m_axis_tready;
  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tvalid = s_axis_tvalid;
endmodule

module fmap_cache #(
    parameter DATA_WIDTH  = 27,
    parameter WRITE_LANES = 16,
    parameter CACHE_DEPTH = 2048,
    parameter LANES       = 32
) (
    input logic clk,
    input logic rst_n,
    input logic [(DATA_WIDTH*WRITE_LANES)-1:0] wr_data,
    input logic                                wr_valid,
    input logic [                         6:0] wr_addr,
    input logic                                wr_en,
    input  logic                  rd_start,
    output logic [DATA_WIDTH-1:0] rd_data_broadcast[0:LANES-1],
    output logic                  rd_valid
);
  logic        is_reading;
  logic [10:0] rd_count;
  logic        rd_valid_pipe_1;
  logic        rd_valid_pipe_2;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      is_reading <= 1'b0;
      rd_count <= '0;
      rd_valid_pipe_1 <= 1'b0;
      rd_valid_pipe_2 <= 1'b0;
      rd_valid <= 1'b0;
      for (int i = 0; i < LANES; i++) rd_data_broadcast[i] <= '0;
    end else begin
      if (rd_start) begin
        is_reading <= 1'b1;
        rd_count <= '0;
      end else if (is_reading) begin
        if (rd_count == CACHE_DEPTH - 1) begin
          is_reading <= 1'b0;
        end else begin
          rd_count <= rd_count + 1;
        end
      end

      rd_valid_pipe_1 <= is_reading;
      rd_valid_pipe_2 <= rd_valid_pipe_1;
      rd_valid <= rd_valid_pipe_2;
      if (rd_valid_pipe_2) begin
        for (int i = 0; i < LANES; i++) rd_data_broadcast[i] <= '0;
      end
    end
  end
endmodule

module tb_preprocess_fmap_merge_gating;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic i_clear = 1'b0;
  logic i_rd_start = 1'b0;

  axis_if #(.DATA_WIDTH(128)) s_axis();

  logic [`FIXED_MANT_WIDTH-1:0] o_fmap_broadcast[0:`ARRAY_SIZE_H-1];
  logic                         o_fmap_valid;
  logic [`BF16_EXP_WIDTH-1:0]   o_cached_emax[0:`ARRAY_SIZE_H-1];

  always #5 clk = ~clk;

  preprocess_fmap dut (
      .clk(clk),
      .rst_n(rst_n),
      .i_clear(i_clear),
      .S_AXIS_ACP_FMAP(s_axis),
      .i_rd_start(i_rd_start),
      .o_fmap_broadcast(o_fmap_broadcast),
      .o_fmap_valid(o_fmap_valid),
      .o_cached_emax(o_cached_emax)
  );

  task automatic axis_idle();
    s_axis.tdata  = '0;
    s_axis.tvalid = 1'b0;
    s_axis.tlast  = 1'b0;
    s_axis.tkeep  = '1;
  endtask

  task automatic send_beat(input logic [127:0] data, input logic last);
    @(negedge clk);
    s_axis.tdata  = data;
    s_axis.tlast  = last;
    s_axis.tvalid = 1'b1;
    wait (s_axis.tready === 1'b1);
    @(negedge clk);
    axis_idle();
  endtask

  task automatic pulse_rd_start();
    @(negedge clk);
    i_rd_start = 1'b1;
    @(negedge clk);
    i_rd_start = 1'b0;
  endtask

  function automatic logic [127:0] make_exp_beat(input int unsigned base_exp);
    logic [127:0] data;

    for (int lane = 0; lane < 8; lane++) begin
      data[(lane*16)+:16] = {1'b0, 8'(base_exp + lane), 7'(lane)};
    end

    return data;
  endfunction

  function automatic logic [255:0] expected_emax_pack(input int unsigned base_exp);
    logic [255:0] data;

    for (int lane = 0; lane < 32; lane++) begin
      data[(lane*`BF16_EXP_WIDTH)+:`BF16_EXP_WIDTH] = 8'(base_exp + lane);
    end

    return data;
  endfunction

  task automatic expect_cached_emax(input int unsigned base_exp);
    for (int lane = 0; lane < `ARRAY_SIZE_H; lane++) begin
      if (o_cached_emax[lane] !== 8'(base_exp + lane)) begin
        $error("cached emax lane %0d mismatch: expected %0d got %0d",
               lane, 8'(base_exp + lane), o_cached_emax[lane]);
        $finish;
      end
    end
  endtask

  initial begin
    logic [127:0] beat_data;
    int unsigned valid_seen;

    axis_idle();
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    send_beat(128'h1111_0000_0000_0000_0000_0000_0000_00a1, 1'b0);
    #1;
    if (dut.fmap_merge_valid !== 1'b0) begin
      $error("first 128-bit beat must not push a 256-bit FIFO word");
      $finish;
    end

    @(negedge clk);
    s_axis.tdata  = 128'h2222_0000_0000_0000_0000_0000_0000_00b2;
    s_axis.tlast  = 1'b0;
    s_axis.tvalid = 1'b1;
    #1;
    if (dut.fmap_merge_valid !== 1'b1 ||
        dut.fmap_merge_data !== {
          128'h2222_0000_0000_0000_0000_0000_0000_00b2,
          128'h1111_0000_0000_0000_0000_0000_0000_00a1
        }) begin
      $error("two 128-bit beats were not merged as {second, first}");
      $finish;
    end
    @(negedge clk);
    axis_idle();

    send_beat(128'h3333_0000_0000_0000_0000_0000_0000_00c3, 1'b1);
    #1;
    if (dut.fmap_merge_valid !== 1'b1 ||
        dut.fmap_merge_data !== {
          128'd0,
          128'h3333_0000_0000_0000_0000_0000_0000_00c3
        }) begin
      $error("odd final 128-bit beat was not zero-padded into one 256-bit word");
      $finish;
    end
    @(negedge clk);

    rst_n = 1'b0;
    axis_idle();
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    pulse_rd_start();
    #1;
    if (dut.fmap_sram_rd_start !== 1'b0) begin
      $error("rd_start must be deferred until fmap cache fill completes");
      $finish;
    end

    for (int i = 0; i < 256; i++) begin
      beat_data = make_exp_beat(32 + i * 8);
      send_beat(beat_data, i == 255);
      if (i == 3) begin
        wait (dut.emax_wr_addr == 1);
        #1;
        if (dut.emax_cache_mem[0] !== expected_emax_pack(32)) begin
          $error("first emax cache group was not packed as 32 consecutive exponents");
          $finish;
        end
      end
      if (i < 255 && dut.fmap_sram_rd_start === 1'b1) begin
        $error("fmap_sram_rd_start fired before full 2048-element cache fill");
        $finish;
      end
    end

    wait (dut.fmap_sram_rd_start === 1'b1);
    @(posedge clk);
    #1;
    if (dut.fmap_rd_request_pending !== 1'b0) begin
      $error("read request did not clear after deferred rd_start pulse");
      $finish;
    end

    valid_seen = 0;
    while (valid_seen < 32) begin
      @(posedge clk);
      #1;
      if (o_fmap_valid) begin
        expect_cached_emax(32);
        valid_seen++;
      end
    end
    wait (dut.emax_rd_addr == 1);
    @(posedge clk);
    #1;
    expect_cached_emax(64);

    $display("OVERALL: PASS");
    $finish;
  end
endmodule
