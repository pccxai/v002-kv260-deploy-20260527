`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"
`include "npu_interfaces.svh"

module tb_pccx_npu_top_idle_contract;
  logic clk_core = 1'b0;
  logic clk_axi = 1'b0;
  logic rst_n_core = 1'b0;
  logic rst_axi_n = 1'b0;
  logic i_clear = 1'b0;

  axil_if #(.ADDR_W(12), .DATA_W(64)) S_AXIL_CTRL (.clk(clk_axi), .rst_n(rst_axi_n));
  axis_if #(.DATA_WIDTH(128)) S_AXI_HP0_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) S_AXI_HP1_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) S_AXI_HP2_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) S_AXI_HP3_WEIGHT ();
  axis_if #(.DATA_WIDTH(128)) S_AXIS_ACP_FMAP ();
  axis_if #(.DATA_WIDTH(128)) M_AXIS_ACP_RESULT ();

  int pass_count = 0;
  int fail_count = 0;

  always #2.5 clk_core = ~clk_core;
  always #4 clk_axi = ~clk_axi;

  pccx_npu_top dut (
      .clk_core(clk_core),
      .rst_n_core(rst_n_core),
      .clk_axi(clk_axi),
      .rst_axi_n(rst_axi_n),
      .i_clear(i_clear),
      .S_AXIL_CTRL(S_AXIL_CTRL),
      .S_AXI_HP0_WEIGHT(S_AXI_HP0_WEIGHT),
      .S_AXI_HP1_WEIGHT(S_AXI_HP1_WEIGHT),
      .S_AXI_HP2_WEIGHT(S_AXI_HP2_WEIGHT),
      .S_AXI_HP3_WEIGHT(S_AXI_HP3_WEIGHT),
      .S_AXIS_ACP_FMAP(S_AXIS_ACP_FMAP),
      .M_AXIS_ACP_RESULT(M_AXIS_ACP_RESULT)
  );

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

  initial begin
    $display("=== tb_pccx_npu_top_idle_contract start ===");

    S_AXIL_CTRL.awaddr = '0;
    S_AXIL_CTRL.awprot = '0;
    S_AXIL_CTRL.awvalid = 1'b0;
    S_AXIL_CTRL.wdata = '0;
    S_AXIL_CTRL.wstrb = '0;
    S_AXIL_CTRL.wvalid = 1'b0;
    S_AXIL_CTRL.bready = 1'b1;
    S_AXIL_CTRL.araddr = '0;
    S_AXIL_CTRL.arprot = '0;
    S_AXIL_CTRL.arvalid = 1'b0;
    S_AXIL_CTRL.rready = 1'b1;

    S_AXI_HP0_WEIGHT.tdata = '0;
    S_AXI_HP0_WEIGHT.tvalid = 1'b0;
    S_AXI_HP0_WEIGHT.tlast = 1'b0;
    S_AXI_HP0_WEIGHT.tkeep = '1;
    S_AXI_HP1_WEIGHT.tdata = '0;
    S_AXI_HP1_WEIGHT.tvalid = 1'b0;
    S_AXI_HP1_WEIGHT.tlast = 1'b0;
    S_AXI_HP1_WEIGHT.tkeep = '1;
    S_AXI_HP2_WEIGHT.tdata = '0;
    S_AXI_HP2_WEIGHT.tvalid = 1'b0;
    S_AXI_HP2_WEIGHT.tlast = 1'b0;
    S_AXI_HP2_WEIGHT.tkeep = '1;
    S_AXI_HP3_WEIGHT.tdata = '0;
    S_AXI_HP3_WEIGHT.tvalid = 1'b0;
    S_AXI_HP3_WEIGHT.tlast = 1'b0;
    S_AXI_HP3_WEIGHT.tkeep = '1;
    S_AXIS_ACP_FMAP.tdata = '0;
    S_AXIS_ACP_FMAP.tvalid = 1'b0;
    S_AXIS_ACP_FMAP.tlast = 1'b0;
    S_AXIS_ACP_FMAP.tkeep = '1;
    M_AXIS_ACP_RESULT.tready = 1'b1;

    repeat (20) tick_core();
    rst_n_core = 1'b1;
    rst_axi_n = 1'b1;
    repeat (80) tick_core();

    check("no_result_without_work", M_AXIS_ACP_RESULT.tvalid === 1'b0);
    check("result_sideband_known",
          !$isunknown({M_AXIS_ACP_RESULT.tvalid, M_AXIS_ACP_RESULT.tlast,
                       M_AXIS_ACP_RESULT.tkeep, M_AXIS_ACP_RESULT.tdata}));
    check("input_ready_known",
          !$isunknown({S_AXI_HP0_WEIGHT.tready, S_AXI_HP1_WEIGHT.tready,
                       S_AXI_HP2_WEIGHT.tready, S_AXI_HP3_WEIGHT.tready,
                       S_AXIS_ACP_FMAP.tready}));
    check("axil_ready_known",
          !$isunknown({S_AXIL_CTRL.awready, S_AXIL_CTRL.wready, S_AXIL_CTRL.bvalid,
                       S_AXIL_CTRL.arready, S_AXIL_CTRL.rvalid}));

    i_clear = 1'b1;
    repeat (4) tick_core();
    i_clear = 1'b0;
    repeat (20) tick_core();
    check("clear_keeps_result_idle", M_AXIS_ACP_RESULT.tvalid === 1'b0);

    $display("");
    $display("=== Summary ===");
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
