`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"
`include "GEMM_Array.svh"
`include "npu_interfaces.svh"
`include "mem_IO.svh"

module tb_mem_dispatcher_cvo_store_arbitration;
  import isa_pkg::*;

  logic clk_core = 1'b0;
  logic clk_axi = 1'b0;
  logic rst_n_core = 1'b0;
  logic rst_axi_n = 1'b0;

  axis_if #(.DATA_WIDTH(128)) s_acp_fmap();
  axis_if #(.DATA_WIDTH(128)) m_acp_result();
  axis_if #(.DATA_WIDTH(128)) m_l1_fmap();

  memory_control_uop_t load_uop;
  logic                load_valid;
  memory_control_uop_t store_uop;
  logic                store_valid;
  memory_set_uop_t     mem_set_uop;
  logic                mem_set_valid;
  cvo_control_uop_t    cvo_uop;
  logic                cvo_valid;

  logic [15:0] cvo_data;
  logic        cvo_data_valid;
  logic        cvo_data_ready;
  logic [15:0] cvo_result;
  logic        cvo_result_valid;
  logic        cvo_result_ready;

  logic [`AXI_STREAM_WIDTH-1:0] gemm_result_data;
  logic                         gemm_result_valid;
  logic                         gemm_result_ready;

  logic fifo_full;
  logic cvo_busy;
  logic store_busy;
  logic store_done;
  logic memset_done;
  logic [15:0] debug_status;

  int pass_count = 0;
  int fail_count = 0;

  always #1.25 clk_core = ~clk_core;
  always #2.00 clk_axi = ~clk_axi;

  mem_dispatcher dut (
      .clk_core(clk_core),
      .rst_n_core(rst_n_core),
      .clk_axi(clk_axi),
      .rst_axi_n(rst_axi_n),
      .S_AXIS_ACP_FMAP(s_acp_fmap),
      .M_AXIS_ACP_RESULT(m_acp_result),
      .M_AXIS_L1_FMAP(m_l1_fmap),
      .IN_LOAD_uop(load_uop),
      .IN_LOAD_uop_valid(load_valid),
      .IN_STORE_uop(store_uop),
      .IN_store_uop_valid(store_valid),
      .IN_mem_set_uop(mem_set_uop),
      .IN_mem_set_uop_valid(mem_set_valid),
      .IN_CVO_uop(cvo_uop),
      .IN_cvo_uop_valid(cvo_valid),
      .OUT_cvo_data(cvo_data),
      .OUT_cvo_valid(cvo_data_valid),
      .IN_cvo_data_ready(cvo_data_ready),
      .IN_cvo_result(cvo_result),
      .IN_cvo_result_valid(cvo_result_valid),
      .OUT_cvo_result_ready(cvo_result_ready),
      .IN_gemm_result_data(gemm_result_data),
      .IN_gemm_result_valid(gemm_result_valid),
      .OUT_gemm_result_ready(gemm_result_ready),
      .OUT_fifo_full(fifo_full),
      .OUT_cvo_busy(cvo_busy),
      .OUT_store_busy(store_busy),
      .OUT_store_done(store_done),
      .OUT_memset_done(memset_done),
      .OUT_debug_status(debug_status)
  );

  function automatic logic [127:0] store_word(input int idx);
    logic [31:0] idx32;
    begin
      idx32 = idx;
      store_word = {
        32'h5157_0000 ^ idx32,
        32'h7000_0000 | idx32,
        32'h89ab_cdef,
        32'h1000_0000 + idx32
      };
    end
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

  task automatic fail_now(input string msg);
    begin
      check(msg, 1'b0);
      $display("OVERALL: FAIL");
      $fatal(1, "%s", msg);
    end
  endtask

  task automatic tick_core;
    @(posedge clk_core);
    #0.1;
  endtask

  task automatic reset_dut;
    begin
      s_acp_fmap.tdata = '0;
      s_acp_fmap.tvalid = 1'b0;
      s_acp_fmap.tlast = 1'b0;
      s_acp_fmap.tkeep = '1;
      m_acp_result.tready = 1'b0;
      m_l1_fmap.tready = 1'b0;
      load_uop = '0;
      load_valid = 1'b0;
      store_uop = '0;
      store_valid = 1'b0;
      mem_set_uop = '0;
      mem_set_valid = 1'b0;
      cvo_uop = '0;
      cvo_valid = 1'b0;
      cvo_data_ready = 1'b1;
      cvo_result = '0;
      cvo_result_valid = 1'b0;
      gemm_result_data = '0;
      gemm_result_valid = 1'b0;
      rst_n_core = 1'b0;
      rst_axi_n = 1'b0;
      #100;
      rst_n_core = 1'b1;
      rst_axi_n = 1'b1;
      repeat (20) tick_core();
      check("reset idle", !cvo_busy && !store_busy && !store_done);
    end
  endtask

  task automatic launch_cvo(input int length);
    begin
      cvo_uop = '0;
      cvo_uop.cvo_func = CVO_EXP;
      cvo_uop.src_addr = 17'd0;
      cvo_uop.dst_addr = 17'd128;
      cvo_uop.length = 16'(length);
      @(negedge clk_core);
      cvo_valid = 1'b1;
      @(negedge clk_core);
      cvo_valid = 1'b0;
      for (int i = 0; i < 100; i++) begin
        tick_core();
        if (cvo_busy) begin
          check("CVO bridge starts", 1'b1);
          return;
        end
      end
      fail_now("CVO bridge did not start");
    end
  endtask

  task automatic wait_cvo_inputs(input int expected);
    int seen;
    begin
      seen = 0;
      while (seen < expected) begin
        tick_core();
        if (cvo_data_valid && cvo_data_ready) begin
          seen++;
        end
        if (seen == 0 && !cvo_busy) begin
          fail_now("CVO bridge dropped before input stream");
        end
      end
      $display("PASS: CVO bridge fed %0d elements", seen);
      pass_count++;
    end
  endtask

  task automatic issue_store;
    begin
      store_uop = '0;
      store_uop.data_dest = from_GEMM_res_to_L2;
      store_uop.dest_addr = 17'd200;
      @(negedge clk_core);
      store_valid = 1'b1;
      @(negedge clk_core);
      store_valid = 1'b0;
      repeat (2) tick_core();
      check("store becomes active", store_busy);
    end
  endtask

  task automatic hold_store_during_cvo;
    begin
      gemm_result_valid = 1'b1;
      gemm_result_data = store_word(0);
      repeat (10) begin
        tick_core();
        if (!cvo_busy) fail_now("CVO ended before store stall window");
        if (gemm_result_ready) fail_now("GEMM store accepted while CVO owns L2");
      end
      check("GEMM store stalls while CVO owns L2", store_busy && !gemm_result_ready);
    end
  endtask

  task automatic send_cvo_results(input int count);
    int cycles;
    bit accepted;
    begin
      for (int i = 0; i < count; i++) begin
        cvo_result = 16'h2000 + 16'(i);
        cvo_result_valid = 1'b1;
        cycles = 0;
        accepted = 1'b0;
        do begin
          @(negedge clk_core);
          accepted = cvo_result_valid && cvo_result_ready;
          tick_core();
          cycles++;
          if (cycles > 2000) begin
            $display("CVO result timeout idx=%0d ready=%0b busy=%0b cvo_state=%0d total=%0d captured=%0d debug=0x%04x",
                     i, cvo_result_ready, cvo_busy, dut.u_cvo_bridge.state,
                     dut.u_cvo_bridge.total_results, dut.u_cvo_bridge.results_captured,
                     debug_status);
            fail_now("CVO result handshake timeout");
          end
        end while (!accepted);
        cvo_result_valid = 1'b0;
        cvo_result = '0;
      end
      $display("PASS: CVO bridge accepted %0d results", count);
      pass_count++;
    end
  endtask

  task automatic wait_cvo_done;
    begin
      for (int i = 0; i < 2000; i++) begin
        tick_core();
        if (!cvo_busy) begin
          check("CVO bridge completes", 1'b1);
          return;
        end
      end
      fail_now("CVO bridge completion timeout");
    end
  endtask

  task automatic drain_store;
    int accepted;
    int cycles;
    bit accepted_this_cycle;
    begin
      accepted = 0;
      cycles = 0;
      while (accepted < 4) begin
        @(negedge clk_core);
        accepted_this_cycle = gemm_result_valid && gemm_result_ready;
        tick_core();
        cycles++;
        if (accepted_this_cycle) begin
          accepted++;
          if (accepted < 4) begin
            gemm_result_data = store_word(accepted);
          end else begin
            gemm_result_valid = 1'b0;
            gemm_result_data = '0;
          end
        end
        if (cycles > 2000) begin
          $display("GEMM store timeout accepted=%0d ready=%0b valid=%0b store_active=%0b store_port_ready=%0b cvo_busy=%0b cvo_bridge_busy=%0b debug=0x%04x",
                   accepted, gemm_result_ready, gemm_result_valid, dut.store_active,
                   dut.store_port_ready, cvo_busy, dut.cvo_bridge_busy, debug_status);
          fail_now("GEMM store drain timeout");
        end
      end
      $display("PASS: GEMM store accepted %0d words after CVO", accepted);
      pass_count++;

      for (int i = 0; i < 50; i++) begin
        tick_core();
        if (store_done) begin
          check("store done after CVO release", 1'b1);
          return;
        end
      end
      fail_now("store done timeout");
    end
  endtask

  initial begin
    $display("=== tb_mem_dispatcher_cvo_store_arbitration start ===");
    reset_dut();
    launch_cvo(8);
    wait_cvo_inputs(8);
    issue_store();
    hold_store_during_cvo();
    send_cvo_results(8);
    wait_cvo_done();
    drain_store();

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
    fail_now("simulation watchdog timeout");
  end
endmodule
