`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"
`include "GEMM_Array.svh"
`include "npu_interfaces.svh"

module xpm_fifo_axis #(
    parameter int FIFO_DEPTH = 16,
    parameter int TDATA_WIDTH = 128,
    parameter string FIFO_MEMORY_TYPE = "auto",
    parameter string CLOCKING_MODE = "common_clock"
) (
    input  logic                   s_aclk,
    input  logic                   m_aclk,
    input  logic                   s_aresetn,
    input  logic [TDATA_WIDTH-1:0] s_axis_tdata,
    input  logic                   s_axis_tvalid,
    input  logic [TDATA_WIDTH/8-1:0] s_axis_tstrb,
    input  logic [TDATA_WIDTH/8-1:0] s_axis_tkeep,
    input  logic                   s_axis_tlast,
    output logic                   s_axis_tready,
    input  logic                   m_axis_tready,
    output logic [TDATA_WIDTH-1:0] m_axis_tdata,
    output logic                   m_axis_tvalid,
    output logic [TDATA_WIDTH/8-1:0] m_axis_tkeep,
    output logic                   m_axis_tlast
);
  assign s_axis_tready = m_axis_tready;
  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tvalid = s_axis_tvalid;
  assign m_axis_tkeep  = s_axis_tkeep;
  assign m_axis_tlast  = s_axis_tlast;

  wire unused_fifo_inputs = s_aclk ^ m_aclk ^ s_aresetn ^ ^s_axis_tstrb;
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
  localparam int DEPTH = MEMORY_SIZE / WRITE_DATA_WIDTH_A;

  logic [127:0] mem [0:DEPTH-1];
  logic [127:0] pipe_a [0:READ_LATENCY_A-1];
  logic [127:0] pipe_b [0:READ_LATENCY_B-1];

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

  wire unused_mem_params = injectsbiterra ^ injectdbiterra ^ injectsbiterrb ^ injectdbiterrb;
endmodule

module tb_mem_GLOBAL_cache;
  logic clk = 1'b0;
  logic rst_n = 1'b0;

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

  always #5 clk = ~clk;

  mem_GLOBAL_cache dut (
      .clk_core(clk),
      .rst_n_core(rst_n),
      .clk_axi(clk),
      .rst_axi_n(rst_n),
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

  task automatic expect_eq(input string name, input logic [127:0] got, input logic [127:0] exp);
    begin
      if (got !== exp) begin
        $display("FAIL: %s got=0x%032x expected=0x%032x", name, got, exp);
        fail(name);
      end
      $display("PASS: %s = 0x%032x", name, got);
    end
  endtask

  task automatic expect_bit(input string name, input logic got, input logic exp);
    begin
      if (got !== exp) begin
        $display("FAIL: %s got=%0b expected=%0b debug=0x%04x", name, got, exp, debug_status);
        fail(name);
      end
      $display("PASS: %s = %0b", name, got);
    end
  endtask

  task automatic wait_acp_busy(input string name, input int timeout_cycles);
    int cycles;
    begin
      cycles = 0;
      while (acp_busy !== 1'b1) begin
        @(posedge clk);
        cycles++;
        if (cycles > timeout_cycles) begin
          $display("FAIL: %s ACP busy never asserted debug=0x%04x", name, debug_status);
          fail("ACP busy assert timeout");
        end
      end
      $display("PASS: %s ACP busy asserted after %0d cycles", name, cycles);
    end
  endtask

  task automatic wait_acp_idle(input string name, input int timeout_cycles);
    int cycles;
    begin
      cycles = 0;
      while (acp_busy !== 1'b0) begin
        @(posedge clk);
        cycles++;
        if (cycles > timeout_cycles) begin
          $display("FAIL: %s ACP busy stuck debug=0x%04x", name, debug_status);
          fail("ACP busy idle timeout");
        end
      end
      $display("PASS: %s ACP busy deasserted after %0d cycles", name, cycles);
    end
  endtask

  task automatic wait_npu_busy(input string name, input int timeout_cycles);
    int cycles;
    begin
      cycles = 0;
      while (npu_busy !== 1'b1) begin
        @(posedge clk);
        cycles++;
        if (cycles > timeout_cycles) begin
          $display("FAIL: %s NPU busy never asserted debug=0x%04x", name, debug_status);
          fail("NPU busy assert timeout");
        end
      end
      $display("PASS: %s NPU busy asserted after %0d cycles", name, cycles);
    end
  endtask

  task automatic wait_npu_idle(input string name, input int timeout_cycles);
    int cycles;
    begin
      cycles = 0;
      while (npu_busy !== 1'b0) begin
        @(posedge clk);
        cycles++;
        if (cycles > timeout_cycles) begin
          $display("FAIL: %s NPU busy stuck debug=0x%04x", name, debug_status);
          fail("NPU busy idle timeout");
        end
      end
      $display("PASS: %s NPU busy deasserted after %0d cycles", name, cycles);
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
      rst_n = 1'b0;
      repeat (8) @(negedge clk);
      rst_n = 1'b1;
      repeat (4) @(negedge clk);
    end
  endtask

  task automatic start_acp(input logic write_en, input logic [16:0] base_addr, input logic [16:0] end_addr);
    begin
      @(negedge clk);
      acp_write_en = write_en;
      acp_base_addr = base_addr;
      acp_end_addr = end_addr;
      acp_rx_start = 1'b1;
      @(negedge clk);
      acp_rx_start = 1'b0;
    end
  endtask

  task automatic start_npu_read(input logic [16:0] base_addr, input logic [16:0] end_addr);
    begin
      @(negedge clk);
      npu_write_en = 1'b0;
      npu_base_addr = base_addr;
      npu_end_addr = end_addr;
      npu_rx_start = 1'b1;
      @(negedge clk);
      npu_rx_start = 1'b0;
    end
  endtask

  task automatic send_acp_word(input logic [127:0] data, input logic last);
    begin
      @(negedge clk);
      s_acp_fmap.tdata = data;
      s_acp_fmap.tlast = last;
      s_acp_fmap.tkeep = '1;
      s_acp_fmap.tvalid = 1'b1;
      wait (s_acp_fmap.tready === 1'b1);
      @(posedge clk);
      @(negedge clk);
      s_acp_fmap.tvalid = 1'b0;
      s_acp_fmap.tlast = 1'b0;
      s_acp_fmap.tdata = '0;
    end
  endtask

  task automatic send_acp_burst(input int beats);
    int i;
    begin
      if (beats <= 0) fail("send_acp_burst beats must be positive");

      i = 0;
      @(negedge clk);
      s_acp_fmap.tdata = burst_word(i);
      s_acp_fmap.tlast = (i == beats - 1);
      s_acp_fmap.tkeep = '1;
      s_acp_fmap.tvalid = 1'b1;

      while (i < beats) begin
        @(posedge clk);
        if (s_acp_fmap.tready === 1'b1) begin
          i++;
          @(negedge clk);
          if (i < beats) begin
            s_acp_fmap.tdata = burst_word(i);
            s_acp_fmap.tlast = (i == beats - 1);
          end else begin
            s_acp_fmap.tvalid = 1'b0;
            s_acp_fmap.tlast = 1'b0;
            s_acp_fmap.tdata = '0;
          end
        end else begin
          @(negedge clk);
        end
      end
    end
  endtask

  task automatic expect_acp_word(input logic [127:0] data, input logic last);
    begin
      do @(negedge clk); while (m_acp_result.tvalid !== 1'b1);
      expect_eq("ACP result data", m_acp_result.tdata, data);
      expect_eq("ACP result tlast", m_acp_result.tlast, last);
    end
  endtask

  task automatic expect_acp_burst(input int beats);
    int i;
    logic expected_last;
    begin
      if (beats <= 0) fail("expect_acp_burst beats must be positive");

      for (i = 0; i < beats; i++) begin
        do @(negedge clk); while (m_acp_result.tvalid !== 1'b1);
        expected_last = (i == beats - 1);
        if (m_acp_result.tdata !== burst_word(i) || m_acp_result.tlast !== expected_last) begin
          $display(
              "FAIL: ACP burst[%0d] data=0x%032x exp=0x%032x last=%0b exp_last=%0b debug=0x%04x",
              i, m_acp_result.tdata, burst_word(i), m_acp_result.tlast, expected_last,
              debug_status);
          fail("ACP burst readback mismatch");
        end
      end
      $display("PASS: ACP burst readback %0d beats", beats);
    end
  endtask

  task automatic expect_npu_word(input logic [127:0] data, input logic last);
    begin
      do @(negedge clk); while (m_npu_fmap.tvalid !== 1'b1);
      expect_eq("NPU fmap data", m_npu_fmap.tdata, data);
      expect_eq("NPU fmap tlast", m_npu_fmap.tlast, last);
    end
  endtask

  task automatic expect_no_npu_valid(input string name, input int cycles);
    begin
      repeat (cycles) begin
        @(negedge clk);
        if (m_npu_fmap.tvalid === 1'b1) fail(name);
      end
      $display("PASS: %s", name);
    end
  endtask

  task automatic pulse_direct_write(input logic [16:0] addr, input logic [127:0] data);
    begin
      @(negedge clk);
      npu_direct_en = 1'b1;
      npu_direct_valid = 1'b1;
      npu_direct_we = 1'b1;
      npu_direct_addr = addr;
      npu_direct_wdata = data;
      @(negedge clk);
      npu_direct_en = 1'b0;
      npu_direct_valid = 1'b0;
      npu_direct_we = 1'b0;
      npu_direct_addr = '0;
      npu_direct_wdata = '0;
      repeat (3) @(negedge clk);
    end
  endtask

  initial begin
    logic [127:0] words [0:2];
    logic [127:0] direct_word;
    words[0] = 128'h0000_0000_0000_0000_0000_0000_0000_a001;
    words[1] = 128'h0000_0000_0000_0000_0000_0000_0000_a002;
    words[2] = 128'h0000_0000_0000_0000_0000_0000_0000_a003;
    direct_word = 128'hfeed_0000_0000_0000_0000_0000_0000_cafe;

    reset_dut();

    start_acp(1'b1, 17'd3, 17'd6);
    wait_acp_busy("ACP 3-word write", 1000);
    send_acp_word(words[0], 1'b0);
    send_acp_word(words[1], 1'b0);
    send_acp_word(words[2], 1'b1);
    wait_acp_idle("ACP 3-word write", 1000);

    m_acp_result.tready = 1'b0;
    start_acp(1'b0, 17'd3, 17'd6);
    wait_acp_busy("ACP 3-word read", 1000);
    repeat (5) @(negedge clk);
    expect_eq("ACP read holds while result backpressured", m_acp_result.tvalid, 1'b0);
    m_acp_result.tready = 1'b1;
    expect_acp_word(words[0], 1'b0);
    expect_acp_word(words[1], 1'b0);
    expect_acp_word(words[2], 1'b1);
    wait_acp_idle("ACP 3-word read", 1000);

    m_npu_fmap.tready = 1'b0;
    start_npu_read(17'd3, 17'd6);
    wait_npu_busy("NPU 3-word read", 1000);
    expect_eq("NPU read busy while fmap ready low", npu_busy, 1'b1);
    expect_no_npu_valid("NPU read waits for fmap ready", 8);
    m_npu_fmap.tready = 1'b1;
    expect_npu_word(words[0], 1'b0);
    expect_npu_word(words[1], 1'b0);
    expect_npu_word(words[2], 1'b1);
    wait_npu_idle("NPU 3-word read", 1000);

    pulse_direct_write(17'd7, direct_word);
    m_acp_result.tready = 1'b1;
    start_acp(1'b0, 17'd7, 17'd8);
    wait_acp_busy("direct write ACP read", 1000);
    expect_acp_word(direct_word, 1'b1);
    wait_acp_idle("direct write ACP read", 1000);

    @(negedge clk);
    npu_direct_en = 1'b1;
    repeat (2) @(negedge clk);
    start_npu_read(17'd3, 17'd6);
    wait_npu_busy("direct owner held NPU read", 1000);
    expect_eq("NPU read busy while direct owner held", npu_busy, 1'b1);
    expect_no_npu_valid("direct owner stalls NPU read output", 6);
    npu_direct_en = 1'b0;
    expect_npu_word(words[0], 1'b0);
    expect_npu_word(words[1], 1'b0);
    expect_npu_word(words[2], 1'b1);
    wait_npu_idle("NPU read resumes after direct owner release", 1000);

    start_acp(1'b1, 17'h00100, 17'h00200);
    wait_acp_busy("ACP 4096B write", 1000);
    send_acp_burst(256);
    wait_acp_idle("ACP 4096B write", 5000);

    m_acp_result.tready = 1'b1;
    start_acp(1'b0, 17'h00100, 17'h00200);
    wait_acp_busy("ACP 4096B read", 1000);
    expect_acp_burst(256);
    wait_acp_idle("ACP 4096B read", 5000);

    $display("OVERALL: PASS");
    $finish;
  end

  initial begin
    #2ms;
    $display("FAIL: simulation watchdog timeout debug=0x%04x", debug_status);
    fail("simulation watchdog timeout");
  end
endmodule
