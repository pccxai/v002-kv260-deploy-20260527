`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"
`include "GEMM_Array.svh"
`include "npu_interfaces.svh"

module tb_mem_GLOBAL_cache_xpm_cdc_burst;
  localparam int SINGLE_BEATS = 1;
  localparam int BURST_BEATS = 256;
  localparam logic [16:0] BASE_ADDR = 17'h00100;
  localparam logic [16:0] SINGLE_END_ADDR = BASE_ADDR + 17'(SINGLE_BEATS);
  localparam logic [16:0] END_ADDR = 17'h00200;

  logic clk_core = 1'b0;
  logic clk_axi = 1'b0;
  logic rst_n_core = 1'b0;
  logic rst_axi_n = 1'b0;

  axis_if #(.DATA_WIDTH(128)) s_acp_fmap();
  axis_if #(.DATA_WIDTH(128)) m_acp_result();
  axis_if #(.DATA_WIDTH(128)) m_npu_fmap();

  logic        acp_write_en;
  logic [16:0] acp_base_addr;
  logic        acp_rx_start;
  logic [16:0] acp_end_addr;
  logic        acp_busy;
  logic        npu_write_en;
  logic [16:0] npu_base_addr;
  logic        npu_rx_start;
  logic [16:0] npu_end_addr;
  logic        npu_busy;
  logic        npu_direct_en;
  logic        npu_direct_valid;
  logic        npu_direct_we;
  logic [16:0] npu_direct_addr;
  logic [127:0] npu_direct_wdata;
  logic [127:0] npu_wdata;
  logic [127:0] npu_rdata;
  logic [15:0] debug_status;

  always #1.25 clk_core = ~clk_core;  // 400 MHz
  always #2.00 clk_axi  = ~clk_axi;   // 250 MHz

  mem_GLOBAL_cache dut (
      .clk_core(clk_core),
      .rst_n_core(rst_n_core),
      .clk_axi(clk_axi),
      .rst_axi_n(rst_axi_n),
      .S_AXIS_ACP_FMAP(s_acp_fmap),
      .M_AXIS_ACP_RESULT(m_acp_result),
      .M_AXIS_NPU_FMAP(m_npu_fmap),
      .IN_acp_write_en(acp_write_en),
      .IN_acp_base_addr(acp_base_addr),
      .IN_acp_rx_start(acp_rx_start),
      .IN_acp_end_addr(acp_end_addr),
      .OUT_acp_is_busy(acp_busy),
      .IN_npu_write_en(npu_write_en),
      .IN_npu_base_addr(npu_base_addr),
      .IN_npu_rx_start(npu_rx_start),
      .IN_npu_end_addr(npu_end_addr),
      .OUT_npu_is_busy(npu_busy),
      .IN_npu_direct_en(npu_direct_en),
      .IN_npu_direct_valid(npu_direct_valid),
      .IN_npu_direct_we(npu_direct_we),
      .IN_npu_direct_addr(npu_direct_addr),
      .IN_npu_direct_wdata(npu_direct_wdata),
      .IN_npu_wdata(npu_wdata),
      .OUT_npu_rdata(npu_rdata),
      .OUT_debug_status(debug_status)
  );

  task automatic fail(input string msg);
    begin
      $display("OVERALL: FAIL - %s", msg);
      $fatal(1, "%s", msg);
    end
  endtask

  function automatic logic [127:0] burst_word(input int idx);
    logic [31:0] idx32;
    begin
      idx32 = idx;
      burst_word = {
        32'hcafe_0000 ^ idx32,
        32'hface_0000 | idx32,
        32'h0123_4567,
        32'habcd_0000 + idx32
      };
    end
  endfunction

  task automatic axis_idle();
    begin
      s_acp_fmap.tdata = '0;
      s_acp_fmap.tvalid = 1'b0;
      s_acp_fmap.tlast = 1'b0;
      s_acp_fmap.tkeep = '1;
      m_acp_result.tready = 1'b0;
      m_npu_fmap.tready = 1'b0;
    end
  endtask

  task automatic reset_dut();
    begin
      axis_idle();
      acp_write_en = 1'b0;
      acp_base_addr = '0;
      acp_rx_start = 1'b0;
      acp_end_addr = '0;
      npu_write_en = 1'b0;
      npu_base_addr = '0;
      npu_rx_start = 1'b0;
      npu_end_addr = '0;
      npu_direct_en = 1'b0;
      npu_direct_valid = 1'b0;
      npu_direct_we = 1'b0;
      npu_direct_addr = '0;
      npu_direct_wdata = '0;
      npu_wdata = '0;
      rst_n_core = 1'b0;
      rst_axi_n = 1'b0;
      #100;
      rst_n_core = 1'b1;
      rst_axi_n = 1'b1;
      repeat (20) @(posedge clk_core);
      repeat (20) @(posedge clk_axi);
    end
  endtask

  task automatic start_acp(input logic write_en, input logic [16:0] base_addr,
                           input logic [16:0] end_addr);
    begin
      @(negedge clk_core);
      acp_write_en = write_en;
      acp_base_addr = base_addr;
      acp_end_addr = end_addr;
      acp_rx_start = 1'b1;
      @(negedge clk_core);
      acp_rx_start = 1'b0;
    end
  endtask

  task automatic wait_acp_busy(input string phase);
    int cycles;
    begin
      cycles = 0;
      while (acp_busy !== 1'b1) begin
        @(posedge clk_core);
        cycles++;
        if (cycles > 1000) begin
          $display("FAIL: %s busy never asserted debug=0x%04x", phase, debug_status);
          fail("ACP busy assert timeout");
        end
      end
      $display("PASS: %s busy asserted after %0d core cycles", phase, cycles);
    end
  endtask

  task automatic wait_acp_idle(input string phase);
    int cycles;
    begin
      cycles = 0;
      while (acp_busy !== 1'b0) begin
        @(posedge clk_core);
        cycles++;
        if (cycles > 20000) begin
          $display("FAIL: %s busy stuck debug=0x%04x", phase, debug_status);
          fail("ACP busy idle timeout");
        end
      end
      $display("PASS: %s busy deasserted after %0d core cycles", phase, cycles);
    end
  endtask

  task automatic send_acp_burst(input int beats);
    int idx;
    int cycles;
    begin
      idx = 0;
      cycles = 0;
      @(negedge clk_axi);
      s_acp_fmap.tdata = burst_word(0);
      s_acp_fmap.tlast = (beats == 1);
      s_acp_fmap.tkeep = '1;
      s_acp_fmap.tvalid = 1'b1;

      while (idx < beats) begin
        @(posedge clk_axi);
        cycles++;
        if (s_acp_fmap.tvalid === 1'b1 && s_acp_fmap.tready === 1'b1) begin
          idx++;
          @(negedge clk_axi);
          if (idx < beats) begin
            s_acp_fmap.tdata = burst_word(idx);
            s_acp_fmap.tlast = (idx == beats - 1);
          end else begin
            s_acp_fmap.tvalid = 1'b0;
            s_acp_fmap.tlast = 1'b0;
            s_acp_fmap.tdata = '0;
          end
        end

        if (cycles > 100000) begin
          $display("FAIL: ACP input accepted %0d/%0d beats debug=0x%04x tready=%0b",
                   idx, beats, debug_status, s_acp_fmap.tready);
          fail("ACP input burst timeout");
        end
      end
      $display("PASS: ACP input accepted %0d beats in %0d axi cycles", idx, cycles);
    end
  endtask

  task automatic expect_acp_burst(input int beats);
    int idx;
    int cycles;
    logic expected_last;
    begin
      idx = 0;
      cycles = 0;
      while (idx < beats) begin
        @(posedge clk_axi);
        cycles++;
        if (m_acp_result.tvalid === 1'b1 && m_acp_result.tready === 1'b1) begin
          expected_last = (idx == beats - 1);
          if (m_acp_result.tdata !== burst_word(idx) || m_acp_result.tlast !== expected_last) begin
            $display("FAIL: ACP result[%0d] data=0x%032x exp=0x%032x last=%0b exp_last=%0b debug=0x%04x",
                     idx, m_acp_result.tdata, burst_word(idx), m_acp_result.tlast,
                     expected_last, debug_status);
            fail("ACP result burst mismatch");
          end
          idx++;
        end

        if (cycles > 100000) begin
          $display("FAIL: ACP result produced %0d/%0d beats debug=0x%04x tvalid=%0b tlast=%0b",
                   idx, beats, debug_status, m_acp_result.tvalid, m_acp_result.tlast);
          fail("ACP result burst timeout");
        end
      end
      $display("PASS: ACP result produced %0d beats in %0d axi cycles", idx, cycles);
    end
  endtask

  initial begin
    reset_dut();

    start_acp(1'b1, BASE_ADDR, SINGLE_END_ADDR);
    wait_acp_busy("ACP 16B write");
    send_acp_burst(SINGLE_BEATS);
    wait_acp_idle("ACP 16B write");

    m_acp_result.tready = 1'b1;
    start_acp(1'b0, BASE_ADDR, SINGLE_END_ADDR);
    wait_acp_busy("ACP 16B read");
    expect_acp_burst(SINGLE_BEATS);
    wait_acp_idle("ACP 16B read");

    start_acp(1'b1, BASE_ADDR, END_ADDR);
    wait_acp_busy("ACP 4096B write");
    send_acp_burst(BURST_BEATS);
    wait_acp_idle("ACP 4096B write");

    m_acp_result.tready = 1'b1;
    start_acp(1'b0, BASE_ADDR, END_ADDR);
    wait_acp_busy("ACP 4096B read");
    expect_acp_burst(BURST_BEATS);
    wait_acp_idle("ACP 4096B read");

    $display("OVERALL: PASS");
    $finish;
  end

  initial begin
    #2ms;
    $display("FAIL: simulation watchdog timeout debug=0x%04x", debug_status);
    fail("simulation watchdog timeout");
  end
endmodule
