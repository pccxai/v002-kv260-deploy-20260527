`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"
`include "npu_interfaces.svh"

module tb_mem_HP_buffer_sideband_contract;
  logic clk_core = 1'b0;
  logic clk_axi = 1'b0;
  logic rst_n_core = 1'b0;
  logic rst_axi_n = 1'b0;

  axis_if #(.DATA_WIDTH(128)) S_AXI_HP0_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) S_AXI_HP1_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) S_AXI_HP2_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) S_AXI_HP3_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) M_CORE_HP0_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) M_CORE_HP1_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) M_CORE_HP2_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) M_CORE_HP3_WEIGHT ();

  int pass_count = 0;
  int fail_count = 0;

  always #2.5 clk_core = ~clk_core;
  always #4 clk_axi = ~clk_axi;

  mem_HP_buffer dut (
      .clk_core(clk_core),
      .rst_n_core(rst_n_core),
      .clk_axi(clk_axi),
      .rst_axi_n(rst_axi_n),
      .S_AXI_HP0_WEIGHT(S_AXI_HP0_WEIGHT),
      .S_AXI_HP1_WEIGHT(S_AXI_HP1_WEIGHT),
      .S_AXI_HP2_WEIGHT(S_AXI_HP2_WEIGHT),
      .S_AXI_HP3_WEIGHT(S_AXI_HP3_WEIGHT),
      .M_CORE_HP0_WEIGHT(M_CORE_HP0_WEIGHT),
      .M_CORE_HP1_WEIGHT(M_CORE_HP1_WEIGHT),
      .M_CORE_HP2_WEIGHT(M_CORE_HP2_WEIGHT),
      .M_CORE_HP3_WEIGHT(M_CORE_HP3_WEIGHT)
  );

  task automatic tick_axi;
    begin
      @(posedge clk_axi);
      #1;
    end
  endtask

  task automatic tick_core;
    begin
      @(posedge clk_core);
      #1;
    end
  endtask

  task automatic check(input string name, input bit ok);
    begin
      if (ok) begin
        $display("PASS [%s]", name);
        pass_count++;
      end else begin
        $display("FAIL [%s]", name);
        fail_count++;
      end
    end
  endtask

`define SEND_CHECK_HP(N, DATA_VALUE) \
  begin \
    int guard; \
    S_AXI_HP``N``_WEIGHT.tdata  = DATA_VALUE; \
    S_AXI_HP``N``_WEIGHT.tkeep  = 16'hffff; \
    S_AXI_HP``N``_WEIGHT.tlast  = 1'b1; \
    S_AXI_HP``N``_WEIGHT.tvalid = 1'b1; \
    guard = 0; \
    do begin \
      tick_axi(); \
      guard++; \
    end while (S_AXI_HP``N``_WEIGHT.tready !== 1'b1 && guard < 80); \
    check($sformatf("hp%0d input handshake", N), guard < 80); \
    S_AXI_HP``N``_WEIGHT.tvalid = 1'b0; \
    S_AXI_HP``N``_WEIGHT.tdata  = '0; \
    S_AXI_HP``N``_WEIGHT.tlast  = 1'b0; \
    guard = 0; \
    do begin \
      tick_core(); \
      guard++; \
    end while (M_CORE_HP``N``_WEIGHT.tvalid !== 1'b1 && guard < 220); \
    check($sformatf("hp%0d output valid", N), guard < 220); \
    check($sformatf("hp%0d output data", N), \
          M_CORE_HP``N``_WEIGHT.tdata === DATA_VALUE); \
    check($sformatf("hp%0d output tkeep", N), \
          M_CORE_HP``N``_WEIGHT.tkeep === 16'hffff); \
    check($sformatf("hp%0d output tlast", N), \
          M_CORE_HP``N``_WEIGHT.tlast === 1'b0); \
  end

  initial begin
    $display("=== tb_mem_HP_buffer_sideband_contract start ===");

    S_AXI_HP0_WEIGHT.tdata = '0;
    S_AXI_HP0_WEIGHT.tvalid = 1'b0;
    S_AXI_HP0_WEIGHT.tkeep = 16'hffff;
    S_AXI_HP0_WEIGHT.tlast = 1'b0;
    S_AXI_HP1_WEIGHT.tdata = '0;
    S_AXI_HP1_WEIGHT.tvalid = 1'b0;
    S_AXI_HP1_WEIGHT.tkeep = 16'hffff;
    S_AXI_HP1_WEIGHT.tlast = 1'b0;
    S_AXI_HP2_WEIGHT.tdata = '0;
    S_AXI_HP2_WEIGHT.tvalid = 1'b0;
    S_AXI_HP2_WEIGHT.tkeep = 16'hffff;
    S_AXI_HP2_WEIGHT.tlast = 1'b0;
    S_AXI_HP3_WEIGHT.tdata = '0;
    S_AXI_HP3_WEIGHT.tvalid = 1'b0;
    S_AXI_HP3_WEIGHT.tkeep = 16'hffff;
    S_AXI_HP3_WEIGHT.tlast = 1'b0;

    M_CORE_HP0_WEIGHT.tready = 1'b1;
    M_CORE_HP1_WEIGHT.tready = 1'b1;
    M_CORE_HP2_WEIGHT.tready = 1'b1;
    M_CORE_HP3_WEIGHT.tready = 1'b1;

    repeat (16) tick_core();
    rst_n_core = 1'b1;
    rst_axi_n = 1'b1;
    repeat (80) tick_core();

    check("hp0 sideband known after reset",
          !$isunknown({M_CORE_HP0_WEIGHT.tkeep, M_CORE_HP0_WEIGHT.tlast}));
    check("hp1 sideband known after reset",
          !$isunknown({M_CORE_HP1_WEIGHT.tkeep, M_CORE_HP1_WEIGHT.tlast}));
    check("hp2 sideband known after reset",
          !$isunknown({M_CORE_HP2_WEIGHT.tkeep, M_CORE_HP2_WEIGHT.tlast}));
    check("hp3 sideband known after reset",
          !$isunknown({M_CORE_HP3_WEIGHT.tkeep, M_CORE_HP3_WEIGHT.tlast}));

    `SEND_CHECK_HP(0, 128'h0000_0000_0000_0000_0000_0000_1234_0000)
    `SEND_CHECK_HP(1, 128'h1111_0000_0000_0000_0000_0000_1234_0001)
    `SEND_CHECK_HP(2, 128'h2222_0000_0000_0000_0000_0000_1234_0002)
    `SEND_CHECK_HP(3, 128'h3333_0000_0000_0000_0000_0000_1234_0003)

    $display("");
    $display("PASS: %0d / %0d", pass_count, pass_count + fail_count);
    $display("FAIL: %0d", fail_count);
    if (fail_count == 0) begin
      $display("OVERALL: PASS");
      $finish;
    end
    $display("OVERALL: FAIL");
    $finish;
  end
endmodule
