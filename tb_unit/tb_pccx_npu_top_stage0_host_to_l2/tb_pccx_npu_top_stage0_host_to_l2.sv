`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"
`include "npu_interfaces.svh"

module tb_pccx_npu_top_stage0_host_to_l2;
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

  always #1.25 clk_core = ~clk_core;
  always #2.00 clk_axi = ~clk_axi;

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

  function automatic logic [63:0] encode_memset(
      input logic [1:0] dest_cache,
      input logic [5:0] dest_addr,
      input logic [15:0] a_value,
      input logic [15:0] b_value,
      input logic [15:0] c_value
  );
    encode_memset = {4'h3, dest_cache, dest_addr, a_value, b_value, c_value, 4'h0};
  endfunction

  function automatic logic [63:0] encode_memcpy(
      input logic from_device,
      input logic to_device,
      input logic [16:0] dest_addr,
      input logic [16:0] src_addr,
      input logic [16:0] aux_addr,
      input logic [5:0] shape_ptr_addr,
      input logic async_op
  );
    encode_memcpy = {
      4'h2, from_device, to_device, dest_addr, src_addr, aux_addr, shape_ptr_addr, async_op
    };
  endfunction

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

  task automatic axil_write64(input logic [11:0] addr, input logic [63:0] data);
    begin
      @(negedge clk_core);
      S_AXIL_CTRL.awaddr  = addr;
      S_AXIL_CTRL.awprot  = '0;
      S_AXIL_CTRL.awvalid = 1'b1;
      S_AXIL_CTRL.wdata   = data;
      S_AXIL_CTRL.wstrb   = '1;
      S_AXIL_CTRL.wvalid  = 1'b0;

      do @(posedge clk_core); while (S_AXIL_CTRL.awready !== 1'b1);
      @(negedge clk_core);
      S_AXIL_CTRL.awvalid = 1'b0;
      S_AXIL_CTRL.wvalid  = 1'b1;

      do @(posedge clk_core); while (S_AXIL_CTRL.wready !== 1'b1);
      @(negedge clk_core);
      S_AXIL_CTRL.wvalid = 1'b0;
      S_AXIL_CTRL.wdata  = '0;

      do @(posedge clk_core); while (S_AXIL_CTRL.bvalid !== 1'b1);
      @(negedge clk_core);
    end
  endtask

  task automatic submit_program(input logic [63:0] word);
    begin
      axil_write64(12'h000, word);
      axil_write64(12'h008, 64'h1);
    end
  endtask

  task automatic send_acp_word(input logic [127:0] data);
    int cycles;
    begin
      cycles = 0;
      @(negedge clk_axi);
      S_AXIS_ACP_FMAP.tdata  = data;
      S_AXIS_ACP_FMAP.tkeep  = '1;
      S_AXIS_ACP_FMAP.tlast  = 1'b1;
      S_AXIS_ACP_FMAP.tvalid = 1'b1;

      while (!(S_AXIS_ACP_FMAP.tvalid === 1'b1 && S_AXIS_ACP_FMAP.tready === 1'b1)) begin
        @(posedge clk_axi);
        cycles++;
        if (cycles > 1000) begin
          $display("ACP source handshake timeout ext_valid=%0b ext_ready=%0b bridge_valid=%0b bridge_ready=%0b cdc_s_valid=%0b cdc_s_ready=%0b",
                   S_AXIS_ACP_FMAP.tvalid,
                   S_AXIS_ACP_FMAP.tready,
                   dut.S_AXIS_ACP_FMAP.tvalid,
                   dut.S_AXIS_ACP_FMAP.tready,
                   dut.u_mem_dispatcher.u_l2_cache.u_acp_cdc.S_AXIS_ACP_FMAP.tvalid,
                   dut.u_mem_dispatcher.u_l2_cache.u_acp_cdc.S_AXIS_ACP_FMAP.tready);
          check("ACP source handshake", 1'b0);
          return;
        end
      end
      $display("ACP source beat accepted after %0d axi cycles ext_valid=%0b dut_port_valid=%0b ext_ready=%0b bridge_valid=%0b bridge_ready=%0b cdc_s_valid=%0b cdc_s_ready=%0b",
               cycles,
               S_AXIS_ACP_FMAP.tvalid,
               dut.S_AXIS_ACP_FMAP.tvalid,
               S_AXIS_ACP_FMAP.tready,
               dut.S_AXIS_ACP_FMAP.tvalid,
               dut.S_AXIS_ACP_FMAP.tready,
               dut.u_mem_dispatcher.u_l2_cache.u_acp_cdc.S_AXIS_ACP_FMAP.tvalid,
               dut.u_mem_dispatcher.u_l2_cache.u_acp_cdc.S_AXIS_ACP_FMAP.tready);
      @(negedge clk_axi);
      S_AXIS_ACP_FMAP.tvalid = 1'b0;
      S_AXIS_ACP_FMAP.tlast  = 1'b0;
      S_AXIS_ACP_FMAP.tdata  = '0;
    end
  endtask

  task automatic dump_state(input string label);
    begin
      $display(
          "%s: mem_debug=0x%04x l2_debug=0x%04x acp_busy=%0b acp_ptr=%0d acp_end=%0d acp_we=%0b ext_valid=%0b dut_port_valid=%0b ext_ready=%0b bridge_valid=%0b bridge_ready=%0b cdc_s_valid=%0b cdc_s_ready=%0b rx_tvalid=%0b rx_tready=%0b rx_fire=%0b",
          label,
          dut.u_mem_dispatcher.OUT_debug_status,
          dut.u_mem_dispatcher.u_l2_cache.OUT_debug_status,
          dut.u_mem_dispatcher.acp_is_busy_wire,
          dut.u_mem_dispatcher.u_l2_cache.acp_ptr,
          dut.u_mem_dispatcher.u_l2_cache.acp_end_addr,
          dut.u_mem_dispatcher.u_l2_cache.acp_write_en,
          S_AXIS_ACP_FMAP.tvalid,
          dut.S_AXIS_ACP_FMAP.tvalid,
          S_AXIS_ACP_FMAP.tready,
          dut.S_AXIS_ACP_FMAP.tvalid,
          dut.S_AXIS_ACP_FMAP.tready,
          dut.u_mem_dispatcher.u_l2_cache.u_acp_cdc.S_AXIS_ACP_FMAP.tvalid,
          dut.u_mem_dispatcher.u_l2_cache.u_acp_cdc.S_AXIS_ACP_FMAP.tready,
          dut.u_mem_dispatcher.u_l2_cache.core_acp_rx_bus.tvalid,
          dut.u_mem_dispatcher.u_l2_cache.core_acp_rx_bus.tready,
          dut.u_mem_dispatcher.u_l2_cache.acp_rx_fire
      );
    end
  endtask

  initial begin
    $display("=== tb_pccx_npu_top_stage0_host_to_l2 start ===");

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

    repeat (20) @(posedge clk_core);
    @(posedge clk_axi);
    rst_n_core = 1'b1;
    rst_axi_n  = 1'b1;
    repeat (80) @(posedge clk_core);
    repeat (80) @(posedge clk_axi);

    // Shape entry 0 = 8 BF16 elements = one 128-bit L2 word.
    submit_program(encode_memset(2'd0, 6'd0, 16'd8, 16'd1, 16'd1));
    repeat (40) @(posedge clk_core);
    dump_state("after memset");

    submit_program(encode_memcpy(1'b1, 1'b0, 17'h00100, 17'd0, 17'd0, 6'd0, 1'b0));

    for (int i = 0; i < 200; i++) begin
      @(posedge clk_core);
      if (dut.u_mem_dispatcher.acp_is_busy_wire === 1'b1) begin
        $display("ACP busy asserted after %0d core cycles", i);
        break;
      end
      if (i == 199) begin
        dump_state("descriptor timeout");
        check("ACP descriptor starts", 1'b0);
      end
    end

    for (int i = 0; i < 200; i++) begin
      @(posedge clk_core);
      if (dut.u_mem_dispatcher.u_l2_cache.acp_write_en === 1'b1 &&
          dut.u_mem_dispatcher.u_l2_cache.core_acp_rx_bus.tready === 1'b1) begin
        $display("ACP write datapath ready after %0d core cycles", i);
        break;
      end
      if (i == 199) begin
        dump_state("write datapath ready timeout");
        check("ACP write datapath becomes ready", 1'b0);
      end
    end

    dump_state("before acp beat");
    send_acp_word(128'h0123_4567_89ab_cdef_0011_2233_4455_6677);
    repeat (20) @(posedge clk_core);
    dump_state("after acp beat");

    for (int i = 0; i < 2000; i++) begin
      @(posedge clk_core);
      if (dut.u_mem_dispatcher.acp_is_busy_wire === 1'b0) begin
        $display("ACP busy deasserted after %0d core cycles", i);
        check("HOST->L2 one-word ACP write completes", 1'b1);
        break;
      end
      if (i == 1999) begin
        dump_state("busy timeout");
        check("HOST->L2 one-word ACP write completes", 1'b0);
      end
    end

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

  initial begin
    #2ms;
    dump_state("watchdog");
    check("watchdog", 1'b0);
    $display("OVERALL: FAIL");
    $finish;
  end
endmodule
