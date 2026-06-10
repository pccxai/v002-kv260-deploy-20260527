`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"
`include "GEMM_Array.svh"

module tb_preprocess_bf16_fixed_pipeline;
  logic clk = 1'b0;
  logic rst_n = 1'b0;

  logic [255:0] s_axis_tdata;
  logic         s_axis_tvalid;
  logic         s_axis_tready;
  logic [431:0] m_axis_tdata;
  logic         m_axis_tvalid;
  logic         m_axis_tready = 1'b1;

  always #5 clk = ~clk;

  preprocess_bf16_fixed_pipeline dut (
      .clk(clk),
      .rst_n(rst_n),
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tvalid(s_axis_tvalid),
      .s_axis_tready(s_axis_tready),
      .m_axis_tdata(m_axis_tdata),
      .m_axis_tvalid(m_axis_tvalid),
      .m_axis_tready(m_axis_tready)
  );

  function automatic logic [15:0] make_bf16(
      input logic sign,
      input logic [7:0] exp,
      input logic [6:0] mant
  );
    return {sign, exp, mant};
  endfunction

  function automatic logic [255:0] make_word(input int block_id, input int half_id);
    logic [255:0] data;
    logic sign;
    logic [7:0] exp;
    logic [6:0] mant;

    for (int i = 0; i < 16; i++) begin
      sign = ((i + block_id + half_id) % 5) == 0;
      exp  = 8'(8'd90 + ((block_id * 11 + half_id * 7 + i * 3) % 34));
      mant = 7'((block_id * 13 + half_id * 19 + i * 5) & 7'h7f);
      data[(i*16)+:16] = make_bf16(sign, exp, mant);
    end

    return data;
  endfunction

  function automatic logic [7:0] max_exp_16(input logic [255:0] data);
    logic [7:0] max_val;

    max_val = 8'd0;
    for (int i = 0; i < 16; i++) begin
      if (data[(i*16)+7+:8] > max_val) max_val = data[(i*16)+7+:8];
    end

    return max_val;
  endfunction

  function automatic logic [7:0] max_exp_32(input logic [255:0] low, input logic [255:0] high);
    logic [7:0] low_max;
    logic [7:0] high_max;

    low_max  = max_exp_16(low);
    high_max = max_exp_16(high);
    return (low_max > high_max) ? low_max : high_max;
  endfunction

  function automatic logic [26:0] fixed_model(input logic [15:0] word, input logic [7:0] global_emax);
    logic        sign;
    logic [7:0]  exp;
    logic [6:0]  mant;
    logic [26:0] base_mant;
    logic [7:0]  delta_e;
    logic [26:0] shifted_mant;

    sign      = word[15];
    exp       = word[14:7];
    mant      = word[6:0];
    base_mant = (exp == 0) ? {7'b0, 8'h0, mant, 12'b0} : {7'b0, 8'h1, mant, 12'b0};
    delta_e   = global_emax - exp;
    shifted_mant = (delta_e >= 27) ? 27'd0 : (base_mant >> delta_e);

    return sign ? (~shifted_mant + 1'b1) : shifted_mant;
  endfunction

  task automatic drive_idle();
    s_axis_tdata  = '0;
    s_axis_tvalid = 1'b0;
  endtask

  task automatic send_word(input logic [255:0] data);
    @(negedge clk);
    s_axis_tdata  = data;
    s_axis_tvalid = 1'b1;
    wait (s_axis_tready === 1'b1);
    @(posedge clk);
    @(negedge clk);
    drive_idle();
  endtask

  task automatic wait_output(output logic [431:0] data);
    do begin
      @(negedge clk);
    end while (m_axis_tvalid !== 1'b1);
    data = m_axis_tdata;
  endtask

  task automatic check_output(
      input logic [431:0] got,
      input logic [255:0] source_word,
      input logic [7:0] global_emax,
      input string label
  );
    logic [26:0] expected;

    for (int i = 0; i < 16; i++) begin
      expected = fixed_model(source_word[(i*16)+:16], global_emax);
      if (got[(i*27)+:27] !== expected) begin
        $error("%s lane %0d mismatch: got=%h expected=%h", label, i, got[(i*27)+:27], expected);
        $finish;
      end
    end
  endtask

  initial begin
    logic [255:0] low_word;
    logic [255:0] high_word;
    logic [431:0] got_low;
    logic [431:0] got_high;
    logic [7:0]   global_emax;

    drive_idle();
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    low_word    = make_word(0, 0);
    high_word   = make_word(0, 1);
    global_emax = max_exp_32(low_word, high_word);

    send_word(low_word);
    if (s_axis_tready !== 1'b1) begin
      $error("pipeline unexpectedly backpressured before high half");
      $finish;
    end

    send_word(high_word);
    #1;
    if (s_axis_tready !== 1'b0) begin
      $error("reduce phase must deassert s_axis_tready for one cycle");
      $finish;
    end

    wait_output(got_low);
    check_output(got_low, low_word, global_emax, "low");
    wait_output(got_high);
    check_output(got_high, high_word, global_emax, "high");

    low_word    = make_word(1, 0);
    high_word   = make_word(1, 1);
    global_emax = max_exp_32(low_word, high_word);

    send_word(low_word);
    send_word(high_word);
    wait_output(got_low);
    check_output(got_low, low_word, global_emax, "second low");
    wait_output(got_high);
    check_output(got_high, high_word, global_emax, "second high");

    $display("OVERALL: PASS");
    $finish;
  end
endmodule
