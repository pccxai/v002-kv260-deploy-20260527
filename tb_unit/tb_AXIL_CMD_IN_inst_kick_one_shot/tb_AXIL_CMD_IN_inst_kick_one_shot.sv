`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"

module tb_AXIL_CMD_IN_inst_kick_one_shot;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic clear = 1'b0;

  logic [11:0] s_awaddr;
  logic [2:0]  s_awprot;
  logic        s_awvalid;
  logic        s_awready;
  logic [`ISA_WIDTH-1:0] s_wdata;
  logic [(`ISA_WIDTH/8)-1:0] s_wstrb;
  logic        s_wvalid;
  logic        s_wready;
  logic [1:0]  s_bresp;
  logic        s_bvalid;
  logic        s_bready;

  logic [`ISA_WIDTH-1:0] out_data;
  logic                  out_valid;
  logic                  decoder_ready;

  int valid_count;
  int memcpy_count;
  int kick_count;
  int other_count;

  localparam logic [`ISA_WIDTH-1:0] MEMCPY_WORD = 64'h2123_4567_89ab_cdef;
  localparam logic [`ISA_WIDTH-1:0] KICK_WORD = 64'h8000_0000_0000_0000;

  always #5 clk = ~clk;

  AXIL_CMD_IN dut (
      .clk(clk),
      .rst_n(rst_n),
      .IN_clear(clear),
      .s_awaddr(s_awaddr),
      .s_awprot(s_awprot),
      .s_awvalid(s_awvalid),
      .s_awready(s_awready),
      .s_wdata(s_wdata),
      .s_wstrb(s_wstrb),
      .s_wvalid(s_wvalid),
      .s_wready(s_wready),
      .s_bresp(s_bresp),
      .s_bvalid(s_bvalid),
      .s_bready(s_bready),
      .OUT_data(out_data),
      .OUT_valid(out_valid),
      .IN_decoder_ready(decoder_ready)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_count <= 0;
      memcpy_count <= 0;
      kick_count <= 0;
      other_count <= 0;
    end else if (out_valid && decoder_ready) begin
      valid_count <= valid_count + 1;
      if (out_data == MEMCPY_WORD) memcpy_count <= memcpy_count + 1;
      else if (out_data == KICK_WORD) kick_count <= kick_count + 1;
      else other_count <= other_count + 1;
      $display("OUT[%0d] data=0x%016x opcode=0x%01x", valid_count, out_data, out_data[63:60]);
    end
  end

  task automatic fail(input string msg);
    begin
      $display("OVERALL: FAIL - %s", msg);
      $fatal(1, "%s", msg);
    end
  endtask

  task automatic axil_write64(input logic [11:0] addr, input logic [`ISA_WIDTH-1:0] data);
    begin
      @(negedge clk);
      s_awaddr  = addr;
      s_awvalid = 1'b1;
      s_wdata   = data;
      s_wstrb   = '1;
      s_wvalid  = 1'b0;

      do @(posedge clk); while (s_awready !== 1'b1);
      @(negedge clk);
      s_awvalid = 1'b0;
      s_wvalid  = 1'b1;

      do @(posedge clk); while (s_wready !== 1'b1);
      @(negedge clk);
      s_wvalid = 1'b0;
      s_wdata  = '0;

      do @(posedge clk); while (s_bvalid !== 1'b1);
      @(negedge clk);
    end
  endtask

  initial begin
    $display("=== tb_AXIL_CMD_IN_inst_kick_one_shot start ===");

    s_awaddr = '0;
    s_awprot = '0;
    s_awvalid = 1'b0;
    s_wdata = '0;
    s_wstrb = '0;
    s_wvalid = 1'b0;
    s_bready = 1'b1;
    decoder_ready = 1'b1;

    repeat (6) @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(negedge clk);

    axil_write64(12'h000, MEMCPY_WORD);
    axil_write64(12'h008, 64'h1);

    repeat (30) @(negedge clk);

    if (memcpy_count != 1) fail($sformatf("MEMCPY decoded %0d times", memcpy_count));
    if (kick_count != 1) fail($sformatf("KICK marker observed %0d times", kick_count));
    if (other_count != 0) fail($sformatf("unexpected output count %0d", other_count));
    if (valid_count != 2) fail($sformatf("total valid count %0d", valid_count));

    $display("PASS: INST/KICK emits MEMCPY once and KICK once");
    $display("OVERALL: PASS");
    $finish;
  end

  initial begin
    #50us;
    fail("watchdog");
  end
endmodule
