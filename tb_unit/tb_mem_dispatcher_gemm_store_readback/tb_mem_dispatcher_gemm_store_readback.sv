`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"
`include "GEMM_Array.svh"
`include "npu_interfaces.svh"
`include "mem_IO.svh"

module xpm_fifo_axis #(
    parameter int FIFO_DEPTH = 16,
    parameter int TDATA_WIDTH = 128,
    parameter string FIFO_MEMORY_TYPE = "auto",
    parameter string CLOCKING_MODE = "common_clock"
) (
    input  logic                    s_aclk,
    input  logic                    m_aclk,
    input  logic                    s_aresetn,
    input  logic [TDATA_WIDTH-1:0]  s_axis_tdata,
    input  logic                    s_axis_tvalid,
    input  logic [TDATA_WIDTH/8-1:0] s_axis_tstrb,
    input  logic [TDATA_WIDTH/8-1:0] s_axis_tkeep,
    input  logic                    s_axis_tlast,
    output logic                    s_axis_tready,
    input  logic                    m_axis_tready,
    output logic [TDATA_WIDTH-1:0]  m_axis_tdata,
    output logic                    m_axis_tvalid,
    output logic [TDATA_WIDTH/8-1:0] m_axis_tkeep,
    output logic                    m_axis_tlast
);
  assign s_axis_tready = m_axis_tready;
  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tvalid = s_axis_tvalid;
  assign m_axis_tkeep  = s_axis_tkeep;
  assign m_axis_tlast  = s_axis_tlast;

  wire unused_fifo_axis_inputs = s_aclk ^ m_aclk ^ s_aresetn ^ ^s_axis_tstrb;
endmodule

module xpm_fifo_sync #(
    parameter int FIFO_WRITE_DEPTH = 16,
    parameter int WRITE_DATA_WIDTH = 32,
    parameter int READ_DATA_WIDTH = WRITE_DATA_WIDTH,
    parameter string FIFO_MEMORY_TYPE = "auto",
    parameter string READ_MODE = "std",
    parameter int FIFO_READ_LATENCY = 1,
    parameter int FULL_RESET_VALUE = 0,
    parameter int PROG_FULL_THRESH = FIFO_WRITE_DEPTH
) (
    input  logic                        sleep,
    input  logic                        rst,
    input  logic                        wr_clk,
    input  logic                        wr_en,
    input  logic [WRITE_DATA_WIDTH-1:0] din,
    input  logic                        rd_en,
    output logic [READ_DATA_WIDTH-1:0]  dout,
    output logic                        empty,
    output logic                        full,
    output logic                        prog_full
);
  localparam int Depth = (FIFO_WRITE_DEPTH < 2) ? 2 : FIFO_WRITE_DEPTH;
  localparam int PtrW = $clog2(Depth);
  localparam int CountW = $clog2(Depth + 1);

  logic [WRITE_DATA_WIDTH-1:0] mem[0:Depth-1];
  logic [PtrW-1:0] wr_ptr;
  logic [PtrW-1:0] rd_ptr;
  logic [CountW-1:0] count;
  logic [READ_DATA_WIDTH-1:0] dout_reg;
  logic do_wr;
  logic do_rd;

  assign empty = (count == '0);
  assign full = (count == CountW'(Depth));
  assign prog_full = (count >= CountW'(PROG_FULL_THRESH));
  assign do_wr = wr_en && !full;
  assign do_rd = rd_en && !empty;
  assign dout = (READ_MODE == "fwft") ? READ_DATA_WIDTH'(mem[rd_ptr]) : dout_reg;

  always_ff @(posedge wr_clk) begin
    if (rst) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count <= '0;
      dout_reg <= '0;
    end else begin
      if (do_wr) begin
        mem[wr_ptr] <= din;
        wr_ptr <= (wr_ptr == PtrW'(Depth - 1)) ? '0 : wr_ptr + PtrW'(1);
      end

      if (do_rd) begin
        if (READ_MODE != "fwft") dout_reg <= READ_DATA_WIDTH'(mem[rd_ptr]);
        rd_ptr <= (rd_ptr == PtrW'(Depth - 1)) ? '0 : rd_ptr + PtrW'(1);
      end

      unique case ({do_wr, do_rd})
        2'b10: count <= count + CountW'(1);
        2'b01: count <= count - CountW'(1);
        default: count <= count;
      endcase
    end
  end

  wire unused_fifo_sync_inputs = sleep;
endmodule

module xpm_fifo_async #(
    parameter string FIFO_MEMORY_TYPE = "auto",
    parameter string ECC_MODE = "no_ecc",
    parameter int RELATED_CLOCKS = 0,
    parameter int FIFO_WRITE_DEPTH = 16,
    parameter int WRITE_DATA_WIDTH = 32,
    parameter int WR_DATA_COUNT_WIDTH = 4,
    parameter int PROG_FULL_THRESH = 8,
    parameter int FULL_RESET_VALUE = 0,
    parameter string READ_MODE = "fwft",
    parameter int FIFO_READ_LATENCY = 0,
    parameter int READ_DATA_WIDTH = WRITE_DATA_WIDTH,
    parameter int RD_DATA_COUNT_WIDTH = 4,
    parameter int PROG_EMPTY_THRESH = 8,
    parameter string DOUT_RESET_VALUE = "0",
    parameter int CDC_SYNC_STAGES = 2,
    parameter int WAKEUP_TIME = 0
) (
    input  logic                         sleep,
    input  logic                         rst,
    input  logic                         wr_clk,
    input  logic                         wr_en,
    input  logic [WRITE_DATA_WIDTH-1:0]  din,
    output logic                         full,
    output logic                         prog_full,
    output logic [WR_DATA_COUNT_WIDTH-1:0] wr_data_count,
    output logic                         overflow,
    output logic                         wr_rst_busy,
    output logic                         almost_full,
    output logic                         wr_ack,
    input  logic                         rd_clk,
    input  logic                         rd_en,
    output logic [READ_DATA_WIDTH-1:0]   dout,
    output logic                         empty,
    output logic                         prog_empty,
    output logic [RD_DATA_COUNT_WIDTH-1:0] rd_data_count,
    output logic                         underflow,
    output logic                         rd_rst_busy,
    output logic                         almost_empty,
    output logic                         data_valid,
    input  logic                         injectsbiterr,
    input  logic                         injectdbiterr,
    output logic                         sbiterr,
    output logic                         dbiterr
);
  localparam int Depth = (FIFO_WRITE_DEPTH < 2) ? 2 : FIFO_WRITE_DEPTH;
  localparam int PtrW = $clog2(Depth);
  localparam int CountW = $clog2(Depth + 1);

  logic [WRITE_DATA_WIDTH-1:0] mem[0:Depth-1];
  logic [PtrW:0] wr_ptr;
  logic [PtrW:0] rd_ptr;
  logic [CountW-1:0] level;

  assign level = CountW'(wr_ptr - rd_ptr);
  assign full = (level >= CountW'(Depth - 1));
  assign empty = (wr_ptr == rd_ptr);
  assign prog_full = (level >= CountW'(PROG_FULL_THRESH));
  assign prog_empty = (level <= CountW'(PROG_EMPTY_THRESH));
  assign almost_full = full;
  assign almost_empty = empty;
  assign wr_data_count = WR_DATA_COUNT_WIDTH'(level);
  assign rd_data_count = RD_DATA_COUNT_WIDTH'(level);
  assign dout = empty ? '0 : READ_DATA_WIDTH'(mem[rd_ptr[PtrW-1:0]]);
  assign data_valid = !empty;
  assign wr_rst_busy = rst;
  assign rd_rst_busy = rst;
  assign sbiterr = 1'b0;
  assign dbiterr = 1'b0;

  always_ff @(posedge wr_clk) begin
    if (rst) begin
      wr_ptr <= '0;
      overflow <= 1'b0;
      wr_ack <= 1'b0;
    end else begin
      overflow <= wr_en && full;
      wr_ack <= wr_en && !full;
      if (wr_en && !full) begin
        mem[wr_ptr[PtrW-1:0]] <= din;
        wr_ptr <= wr_ptr + 1'b1;
      end
    end
  end

  always_ff @(posedge rd_clk) begin
    if (rst) begin
      rd_ptr <= '0;
      underflow <= 1'b0;
    end else begin
      underflow <= rd_en && empty;
      if (rd_en && !empty) rd_ptr <= rd_ptr + 1'b1;
    end
  end

  wire unused_fifo_async_inputs = sleep ^ injectsbiterr ^ injectdbiterr;
endmodule

module xpm_memory_tdpram #(
    parameter int ADDR_WIDTH_A = 17,
    parameter int ADDR_WIDTH_B = 17,
    parameter int WRITE_DATA_WIDTH_A = 128,
    parameter int READ_DATA_WIDTH_A = 128,
    parameter int WRITE_DATA_WIDTH_B = 128,
    parameter int READ_DATA_WIDTH_B = 128,
    parameter int BYTE_WRITE_WIDTH_A = 128,
    parameter int BYTE_WRITE_WIDTH_B = 128,
    parameter int MEMORY_SIZE = 128 * 1024,
    parameter string MEMORY_PRIMITIVE = "auto",
    parameter string CLOCKING_MODE = "common_clock",
    parameter int CASCADE_HEIGHT = 0,
    parameter int READ_LATENCY_A = 7,
    parameter int READ_LATENCY_B = 6,
    parameter string WRITE_MODE_A = "no_change",
    parameter string WRITE_MODE_B = "no_change",
    parameter string MEMORY_INIT_FILE = "none",
    parameter string MEMORY_INIT_PARAM = "0",
    parameter int USE_MEM_INIT = 0,
    parameter int AUTO_SLEEP_TIME = 0,
    parameter string WAKEUP_TIME = "disable_sleep",
    parameter string ECC_MODE = "no_ecc",
    parameter int USE_EMBEDDED_CONSTRAINT = 0
) (
    input  logic clka,
    input  logic rsta,
    input  logic ena,
    input  logic wea,
    input  logic [ADDR_WIDTH_A-1:0] addra,
    input  logic [WRITE_DATA_WIDTH_A-1:0] dina,
    output logic [READ_DATA_WIDTH_A-1:0] douta,
    input  logic regcea,
    input  logic injectsbiterra,
    input  logic injectdbiterra,
    output logic sbiterra,
    output logic dbiterra,
    input  logic clkb,
    input  logic rstb,
    input  logic enb,
    input  logic web,
    input  logic [ADDR_WIDTH_B-1:0] addrb,
    input  logic [WRITE_DATA_WIDTH_B-1:0] dinb,
    output logic [READ_DATA_WIDTH_B-1:0] doutb,
    input  logic regceb,
    input  logic injectsbiterrb,
    input  logic injectdbiterrb,
    output logic sbiterrb,
    output logic dbiterrb
);
  localparam int Depth = MEMORY_SIZE / WRITE_DATA_WIDTH_A;

  logic [127:0] mem[0:Depth-1];
  logic [127:0] pipe_a[0:READ_LATENCY_A-1];
  logic [127:0] pipe_b[0:READ_LATENCY_B-1];

  assign sbiterra = 1'b0;
  assign dbiterra = 1'b0;
  assign sbiterrb = 1'b0;
  assign dbiterrb = 1'b0;

  always_ff @(posedge clka) begin
    if (rsta) begin
      for (int i = 0; i < READ_LATENCY_A; i++) pipe_a[i] <= '0;
      douta <= '0;
    end else if (ena) begin
      if (wea) mem[addra] <= dina;
      pipe_a[0] <= mem[addra];
      for (int i = 1; i < READ_LATENCY_A; i++) pipe_a[i] <= pipe_a[i-1];
      if (regcea) douta <= pipe_a[READ_LATENCY_A-2];
    end
  end

  always_ff @(posedge clkb) begin
    if (rstb) begin
      for (int i = 0; i < READ_LATENCY_B; i++) pipe_b[i] <= '0;
      doutb <= '0;
    end else if (enb) begin
      if (web) mem[addrb] <= dinb;
      pipe_b[0] <= mem[addrb];
      for (int i = 1; i < READ_LATENCY_B; i++) pipe_b[i] <= pipe_b[i-1];
      if (regceb) doutb <= pipe_b[READ_LATENCY_B-2];
    end
  end

  wire unused_mem_inputs = injectsbiterra ^ injectdbiterra ^ injectsbiterrb ^ injectdbiterrb;
endmodule

module tb_mem_dispatcher_gemm_store_readback;
  import isa_pkg::*;

  localparam logic [16:0] RESULT_BASE = 17'h00500;

  logic clk_core = 1'b0;
  logic clk_axi = 1'b0;
  logic rst_n_core = 1'b0;
  logic rst_axi_n = 1'b0;

  axis_if #(.DATA_WIDTH(128)) s_acp_fmap();
  axis_if #(.DATA_WIDTH(128)) m_acp_result();
  axis_if #(.DATA_WIDTH(128)) m_l1_fmap();

  memory_control_uop_t load_uop;
  logic load_valid;
  memory_control_uop_t store_uop;
  logic store_valid;
  memory_set_uop_t mem_set_uop;
  logic mem_set_valid;
  cvo_control_uop_t cvo_uop;
  logic cvo_valid;

  logic [15:0] cvo_data;
  logic cvo_data_valid;
  logic cvo_data_ready;
  logic [15:0] cvo_result;
  logic cvo_result_valid;
  logic cvo_result_ready;

  logic [`AXI_STREAM_WIDTH-1:0] gemm_result_data;
  logic gemm_result_valid;
  logic gemm_result_ready;

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

  function automatic logic [127:0] result_word(input int idx);
    logic [31:0] idx32;
    begin
      idx32 = idx;
      result_word = {
        32'h7100_0000 | idx32,
        32'h6200_1000 | idx32,
        32'h5300_2000 | idx32,
        32'h4400_3000 | idx32
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
      m_acp_result.tready = 1'b1;
      m_l1_fmap.tready = 1'b1;
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

  task automatic write_fmap_shape(
      input logic [5:0] ptr,
      input logic [16:0] x,
      input logic [16:0] y,
      input logic [16:0] z
  );
    begin
      mem_set_uop = '0;
      mem_set_uop.dest_cache = data_to_fmap_shape;
      mem_set_uop.dest_addr = ptr;
      mem_set_uop.a_value = x[15:0];
      mem_set_uop.b_value = y[15:0];
      mem_set_uop.c_value = z[15:0];
      @(negedge clk_core);
      mem_set_valid = 1'b1;
      @(posedge clk_core);
      #0.1;
      check("shape memset done pulse", memset_done === 1'b1);
      @(negedge clk_core);
      mem_set_valid = 1'b0;
      repeat (4) tick_core();
    end
  endtask

  task automatic issue_gemm_store;
    begin
      store_uop = '0;
      store_uop.data_dest = from_GEMM_res_to_L2;
      store_uop.dest_addr = RESULT_BASE;
      store_uop.shape_ptr_addr = 6'd0;
      store_uop.async = SYNC_OP;
      @(negedge clk_core);
      store_valid = 1'b1;
      @(negedge clk_core);
      store_valid = 1'b0;
      repeat (2) tick_core();
      check("store active", store_busy);
    end
  endtask

  task automatic send_gemm_result_words;
    int accepted;
    int cycles;
    bit accepted_this_cycle;
    begin
      accepted = 0;
      cycles = 0;
      gemm_result_data = result_word(0);
      gemm_result_valid = 1'b1;

      while (accepted < 4) begin
        @(negedge clk_core);
        accepted_this_cycle = gemm_result_valid && gemm_result_ready;
        @(posedge clk_core);
        #0.1;
        if (accepted_this_cycle) begin
          accepted++;
          if (accepted < 4) begin
            gemm_result_data = result_word(accepted);
          end else begin
            gemm_result_valid = 1'b0;
            gemm_result_data = '0;
          end
        end
        cycles++;
        if (cycles > 500) begin
          $display("GEMM store timeout accepted=%0d ready=%0b valid=%0b store_busy=%0b debug=0x%04x",
                   accepted, gemm_result_ready, gemm_result_valid, store_busy, debug_status);
          fail_now("GEMM store did not accept 4 words");
        end
      end
      check("GEMM store accepted four words", accepted == 4);

      for (int i = 0; i < 80; i++) begin
        tick_core();
        if (store_done) begin
          check("GEMM store done pulse", 1'b1);
          return;
        end
      end
      fail_now("GEMM store done timeout");
    end
  endtask

  task automatic issue_l2_to_host_readback;
    begin
      load_uop = '0;
      load_uop.data_dest = from_L2_to_host;
      load_uop.src_addr = RESULT_BASE;
      load_uop.shape_ptr_addr = 6'd0;
      load_uop.async = SYNC_OP;
      @(negedge clk_core);
      load_valid = 1'b1;
      @(negedge clk_core);
      load_valid = 1'b0;
    end
  endtask

  task automatic expect_acp_result_words;
    bit expected_last;
    int cycles;
    begin
      for (int i = 0; i < 4; i++) begin
        cycles = 0;
        do begin
          @(negedge clk_axi);
          cycles++;
          if (cycles > 2000) begin
            $display("ACP readback timeout idx=%0d acp_busy=%0b debug=0x%04x l2_debug=0x%04x",
                     i, dut.acp_is_busy_wire, debug_status, dut.u_l2_cache.OUT_debug_status);
            fail_now("ACP readback valid timeout");
          end
        end while (m_acp_result.tvalid !== 1'b1);
        expected_last = (i == 3);
        if (m_acp_result.tdata !== result_word(i) || m_acp_result.tlast !== expected_last) begin
          $display("ACP mismatch idx=%0d data=0x%032x exp=0x%032x last=%0b exp_last=%0b",
                   i, m_acp_result.tdata, result_word(i), m_acp_result.tlast, expected_last);
          fail_now("ACP readback data mismatch");
        end
      end
      check("ACP readback four GEMM words", 1'b1);
    end
  endtask

  initial begin
    $display("=== tb_mem_dispatcher_gemm_store_readback start ===");
    reset_dut();

    write_fmap_shape(6'd0, 17'd32, 17'd1, 17'd1);
    issue_gemm_store();
    send_gemm_result_words();
    issue_l2_to_host_readback();
    expect_acp_result_words();

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
