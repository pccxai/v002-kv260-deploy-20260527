`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"
`include "npu_interfaces.svh"

module tb_pccx_npu_top_stage1_gemm_store_contract;
  localparam logic [16:0] FMAP_BASE = 17'h00100;
  localparam logic [16:0] RESULT_BASE = 17'h00500;
  localparam logic [16:0] PROBE_BASE = 17'h00580;
  localparam int FMAP_WORDS = 256;  // 2048 BF16 elements / 8 per 128-bit word
  localparam int RESULT_WORDS = 4;  // 32 BF16 elements / 8 per 128-bit word
  localparam int PROBE_WORDS = 4;  // 32 BF16 elements / 8 per 128-bit word
  localparam int HP_PREFILL_WORDS = 1024;

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

  function automatic logic [63:0] encode_gemm(
      input logic [16:0] dest_reg,
      input logic [16:0] src_addr,
      input logic [5:0] flags,
      input logic [5:0] size_ptr_addr,
      input logic [5:0] shape_ptr_addr,
      input logic [4:0] parallel_lane
  );
    encode_gemm = {
      4'h1, dest_reg, src_addr, flags, size_ptr_addr, shape_ptr_addr, parallel_lane, 3'b000
    };
  endfunction

  function automatic logic [127:0] hp_weight_word(input logic [3:0] nibble);
    logic [127:0] word;
    begin
      word = '0;
      for (int i = 0; i < 32; i++) word[i*4+:4] = nibble;
      return word;
    end
  endfunction

  function automatic logic [15:0] bf16_word(input int elem_idx);
    int lane;
    logic [6:0] mant;
    begin
      lane = elem_idx % 32;
      mant = (lane * 3) & 7'h7f;
      if (lane == 0) bf16_word = {1'b0, 8'd141, 7'd0};
      else           bf16_word = {1'b0, 8'd127, mant};
    end
  endfunction

  function automatic logic [127:0] fmap_word(input int word_idx);
    logic [127:0] word;
    begin
      word = '0;
      for (int lane = 0; lane < 8; lane++) begin
        word[lane*16+:16] = bf16_word(word_idx * 8 + lane);
      end
      return word;
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

  task automatic init_ports;
    begin
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
    end
  endtask

  task automatic axil_write64(input logic [11:0] addr, input logic [63:0] data);
    begin
      @(negedge clk_core);
      S_AXIL_CTRL.awaddr = addr;
      S_AXIL_CTRL.awprot = '0;
      S_AXIL_CTRL.awvalid = 1'b1;
      S_AXIL_CTRL.wdata = data;
      S_AXIL_CTRL.wstrb = '1;
      S_AXIL_CTRL.wvalid = 1'b0;

      do @(posedge clk_core); while (S_AXIL_CTRL.awready !== 1'b1);
      @(negedge clk_core);
      S_AXIL_CTRL.awvalid = 1'b0;
      S_AXIL_CTRL.wvalid = 1'b1;

      do @(posedge clk_core); while (S_AXIL_CTRL.wready !== 1'b1);
      @(negedge clk_core);
      S_AXIL_CTRL.wvalid = 1'b0;
      S_AXIL_CTRL.wdata = '0;

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

  task automatic send_acp_fmap_words(input int beats);
    int idx;
    int wait_cycles;
    begin
      idx = 0;
      wait_cycles = 0;
      @(negedge clk_axi);
      S_AXIS_ACP_FMAP.tdata = fmap_word(idx);
      S_AXIS_ACP_FMAP.tkeep = '1;
      S_AXIS_ACP_FMAP.tlast = (idx == beats - 1);
      S_AXIS_ACP_FMAP.tvalid = 1'b1;

      while (idx < beats) begin
        @(posedge clk_axi);
        if (S_AXIS_ACP_FMAP.tvalid && S_AXIS_ACP_FMAP.tready) begin
          idx++;
          wait_cycles = 0;
          @(negedge clk_axi);
          if (idx < beats) begin
            S_AXIS_ACP_FMAP.tdata = fmap_word(idx);
            S_AXIS_ACP_FMAP.tlast = (idx == beats - 1);
          end else begin
            S_AXIS_ACP_FMAP.tvalid = 1'b0;
            S_AXIS_ACP_FMAP.tlast = 1'b0;
            S_AXIS_ACP_FMAP.tdata = '0;
          end
        end else begin
          wait_cycles++;
          if (wait_cycles > 20000) fail_now("ACP fmap stream stalled");
          @(negedge clk_axi);
        end
      end
      check("ACP fmap payload accepted", idx == beats);
    end
  endtask

  task automatic send_hp_prefill(input int beats);
    int idx;
    int wait_cycles;
    begin
      idx = 0;
      wait_cycles = 0;
      @(negedge clk_axi);
      S_AXI_HP0_WEIGHT.tdata = hp_weight_word(4'h1);
      S_AXI_HP1_WEIGHT.tdata = hp_weight_word(4'h1);
      S_AXI_HP0_WEIGHT.tkeep = '1;
      S_AXI_HP1_WEIGHT.tkeep = '1;
      S_AXI_HP0_WEIGHT.tlast = 1'b0;
      S_AXI_HP1_WEIGHT.tlast = 1'b0;
      S_AXI_HP0_WEIGHT.tvalid = 1'b1;
      S_AXI_HP1_WEIGHT.tvalid = 1'b1;

      while (idx < beats) begin
        @(posedge clk_axi);
        if (S_AXI_HP0_WEIGHT.tready && S_AXI_HP1_WEIGHT.tready) begin
          idx++;
          wait_cycles = 0;
          @(negedge clk_axi);
          S_AXI_HP0_WEIGHT.tlast = (idx == beats - 1);
          S_AXI_HP1_WEIGHT.tlast = (idx == beats - 1);
        end else begin
          wait_cycles++;
          if (wait_cycles > 20000) fail_now("HP prefill stream stalled");
          @(negedge clk_axi);
        end
      end

      S_AXI_HP0_WEIGHT.tvalid = 1'b0;
      S_AXI_HP1_WEIGHT.tvalid = 1'b0;
      S_AXI_HP0_WEIGHT.tlast = 1'b0;
      S_AXI_HP1_WEIGHT.tlast = 1'b0;
      S_AXI_HP0_WEIGHT.tdata = '0;
      S_AXI_HP1_WEIGHT.tdata = '0;
      check("HP0/HP1 prefill accepted", idx == beats);
    end
  endtask

  task automatic wait_store_done;
    bit saw_fmap;
    bit saw_packed;
    bit saw_debug_gemm_op;
    bit saw_debug_global;
    bit saw_debug_raw;
    bit saw_debug_norm;
    bit saw_debug_packed;
    logic [47:0] raw_or;
    logic [47:0] recovered_or;
    logic [15:0] norm_or;
    begin
      saw_fmap = 1'b0;
      saw_packed = 1'b0;
      saw_debug_gemm_op = 1'b0;
      saw_debug_global = 1'b0;
      saw_debug_raw = 1'b0;
      saw_debug_norm = 1'b0;
      saw_debug_packed = 1'b0;
      for (int i = 0; i < 20000; i++) begin
        @(posedge clk_core);
        saw_fmap |= dut.u_fmap_pre.o_fmap_valid;
        saw_packed |= dut.packed_res_valid;
        saw_debug_gemm_op |= dut.top_debug_status[8];
        saw_debug_global |= dut.top_debug_status[7];
        saw_debug_raw |= dut.top_debug_status[6];
        saw_debug_norm |= dut.top_debug_status[5];
        saw_debug_packed |= dut.top_debug_status[2];
        if (dut.store_done_wire) begin
          @(posedge clk_core);
          raw_or = '0;
          recovered_or = '0;
          norm_or = '0;
          for (int n = 0; n < 32; n++) begin
            raw_or |= dut.raw_res_sum[n];
            recovered_or |= dut.recovered_res_sum[n];
            norm_or |= dut.norm_res_seq[n];
          end
          $display("DIAG raw_or=0x%012x recovered_or=0x%012x norm_or=0x%04x packed=0x%032x",
                   raw_or, recovered_or, norm_or, dut.packed_res_data);
          check("full-top fmap broadcast observed", saw_fmap);
          check("v34 debug GEMM op observed", saw_debug_gemm_op);
          check("v34 debug global_inst observed", saw_debug_global);
          check("v34 debug raw valid observed", saw_debug_raw);
          check("v34 debug norm valid observed", saw_debug_norm);
          check("full-top raw result nonzero", raw_or != '0);
          check("full-top recovered result nonzero", recovered_or != '0);
          check("full-top normalized result nonzero", norm_or != '0);
          check("full-top packed result observed", saw_packed);
          check("full-top packed result nonzero", dut.packed_res_data != '0);
          check("v34 debug packed valid observed", saw_debug_packed);
          check("v34 debug store done observed", dut.top_debug_status[0]);
          check("full-top store done", 1'b1);
          return;
        end
      end
      $display("timeout stat=0x%08x top=0x%04x mem=0x%04x fmap=%0b packed=%0b store_busy=%0b",
               dut.mmio_npu_stat,
               dut.top_debug_status,
               dut.mem_debug_status_wire,
               dut.u_fmap_pre.o_fmap_valid,
               dut.packed_res_valid,
               dut.store_busy_wire);
      fail_now("full-top GEMM store_done timeout");
    end
  endtask

  task automatic expect_result_readback(
      input string label,
      input int words,
      input bit expect_fmap_pattern,
      input bit require_nonzero,
      input bit forbid_fmap_pattern
  );
    int seen;
    int wait_cycles;
    bit saw_nonzero;
    bit matched_fmap_pattern;
    begin
      seen = 0;
      wait_cycles = 0;
      saw_nonzero = 1'b0;
      matched_fmap_pattern = 1'b1;
      while (seen < words) begin
        @(negedge clk_axi);
        if (M_AXIS_ACP_RESULT.tvalid) begin
          if ($isunknown(M_AXIS_ACP_RESULT.tdata)) fail_now("result readback contains X");
          saw_nonzero |= |M_AXIS_ACP_RESULT.tdata;
          if (M_AXIS_ACP_RESULT.tdata !== fmap_word(seen)) matched_fmap_pattern = 1'b0;
          if (expect_fmap_pattern && M_AXIS_ACP_RESULT.tdata !== fmap_word(seen)) begin
            $display("readback mismatch %s[%0d] got=0x%032x exp=0x%032x",
                     label, seen, M_AXIS_ACP_RESULT.tdata, fmap_word(seen));
            fail_now("result readback data mismatch");
          end
          seen++;
          wait_cycles = 0;
        end else begin
          wait_cycles++;
          if (wait_cycles > 20000) fail_now("result readback timeout");
        end
      end
      check({label, " readback words"}, seen == words);
      if (require_nonzero) check({label, " readback nonzero"}, saw_nonzero);
      if (forbid_fmap_pattern) check({label, " overwrote sentinel"}, !matched_fmap_pattern);
    end
  endtask

  initial begin
    $display("=== tb_pccx_npu_top_stage1_gemm_store_contract start ===");
    init_ports();

    repeat (20) @(posedge clk_core);
    @(posedge clk_axi);
    rst_n_core = 1'b1;
    rst_axi_n = 1'b1;
    repeat (80) @(posedge clk_core);
    repeat (80) @(posedge clk_axi);

    submit_program(encode_memset(2'd0, 6'd0, 16'd2048, 16'd1, 16'd1));
    submit_program(encode_memset(2'd0, 6'd1, 16'd32, 16'd1, 16'd1));

    submit_program(encode_memcpy(1'b1, 1'b0, FMAP_BASE, 17'd0, 17'd0, 6'd0, 1'b0));
    send_acp_fmap_words(FMAP_WORDS);

    submit_program(encode_memcpy(1'b1, 1'b0, RESULT_BASE, 17'd0, 17'd0, 6'd1, 1'b0));
    send_acp_fmap_words(RESULT_WORDS);

    submit_program(encode_memcpy(1'b0, 1'b1, 17'd0, RESULT_BASE, 17'd0, 6'd1, 1'b0));
    expect_result_readback("pre-GEMM result sentinel", RESULT_WORDS, 1'b1, 1'b1, 1'b0);

    send_hp_prefill(HP_PREFILL_WORDS);

    submit_program(encode_gemm(RESULT_BASE, FMAP_BASE, 6'h08, 6'd0, 6'd0, 5'd0));
    wait_store_done();

    submit_program(encode_memcpy(1'b0, 1'b1, 17'd0, RESULT_BASE, 17'd0, 6'd1, 1'b0));
    expect_result_readback("full-top GEMM result", RESULT_WORDS, 1'b0, 1'b1, 1'b1);

    submit_program(encode_memset(2'd0, 6'd2, 16'd32, 16'd1, 16'd1));
    submit_program(encode_memcpy(1'b1, 1'b0, PROBE_BASE, 17'd0, 17'd0, 6'd2, 1'b0));
    send_acp_fmap_words(PROBE_WORDS);

    submit_program(encode_memcpy(1'b0, 1'b1, 17'd0, PROBE_BASE, 17'd0, 6'd2, 1'b0));
    expect_result_readback("post-GEMM ACP probe", PROBE_WORDS, 1'b1, 1'b0, 1'b0);

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
    #10ms;
    fail_now("simulation watchdog timeout");
  end
endmodule
