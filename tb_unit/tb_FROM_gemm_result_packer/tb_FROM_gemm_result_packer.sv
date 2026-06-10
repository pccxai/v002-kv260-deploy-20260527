`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"

module tb_FROM_gemm_result_packer;
  localparam int ARRAY_SIZE = 32;
  localparam int LANES_PER_BEAT = 8;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic clear;
  logic capture_enable;
  logic [`BF16_WIDTH-1:0] row_res[0:ARRAY_SIZE-1];
  logic row_res_valid[0:ARRAY_SIZE-1];
  logic [`AXI_STREAM_WIDTH-1:0] packed_data;
  logic packed_valid;
  logic packed_ready;
  logic o_busy;

  int pass_count = 0;
  int fail_count = 0;
  int beat_seen = 0;
  logic [`AXI_STREAM_WIDTH-1:0] prev_valid_data;
  logic [`BF16_WIDTH-1:0] expected_base;

  always #5 clk = ~clk;

  FROM_gemm_result_packer #(.ARRAY_SIZE(ARRAY_SIZE)) dut (
      .clk(clk),
      .rst_n(rst_n),
      .clear(clear),
      .capture_enable(capture_enable),
      .row_res(row_res),
      .row_res_valid(row_res_valid),
      .packed_data(packed_data),
      .packed_valid(packed_valid),
      .packed_ready(packed_ready),
      .o_busy(o_busy)
  );

  task automatic tick;
    begin
      @(posedge clk);
      #1;
    end
  endtask

  function automatic logic [`AXI_STREAM_WIDTH-1:0] expected_word(input int group);
    logic [`AXI_STREAM_WIDTH-1:0] tmp;
    begin
      tmp = '0;
      for (int i = 0; i < LANES_PER_BEAT; i++) begin
        tmp[i*`BF16_WIDTH +: `BF16_WIDTH] = expected_base + (group * LANES_PER_BEAT) + i;
      end
      expected_word = tmp;
    end
  endfunction

  task automatic record_pass(input string name);
    begin
      $display("PASS [%s]", name);
      pass_count++;
    end
  endtask

  task automatic record_fail(input string name);
    begin
      $display("FAIL [%s]", name);
      fail_count++;
    end
  endtask

  always @(posedge clk) begin
    if (rst_n) begin
      if (packed_valid && !packed_ready) begin
        if (beat_seen > 0 && packed_data !== prev_valid_data) begin
          $display("FAIL [axis_hold]: data changed while valid=1 ready=0 old=%h new=%h",
                   prev_valid_data, packed_data);
          fail_count++;
        end
        prev_valid_data <= packed_data;
      end

      if (packed_valid && packed_ready) begin
        if (beat_seen >= 4) begin
          $display("FAIL [extra_beat]: packed_data=%h", packed_data);
          fail_count++;
        end else if (packed_data !== expected_word(beat_seen)) begin
          $display("FAIL [beat_%0d]: packed_data=%h expected=%h",
                   beat_seen, packed_data, expected_word(beat_seen));
          fail_count++;
        end else begin
          $display("PASS [beat_%0d]: packed_data=%h", beat_seen, packed_data);
          pass_count++;
        end
        beat_seen++;
        prev_valid_data <= packed_data;
      end
    end
  end

  initial begin
    $display("=== tb_FROM_gemm_result_packer start ===");
    clear = 1'b0;
    capture_enable = 1'b1;
    packed_ready = 1'b0;
    expected_base = 16'h5000;
    for (int i = 0; i < ARRAY_SIZE; i++) begin
      row_res[i] = 16'h5000 + i;
      row_res_valid[i] = 1'b0;
    end

    repeat (4) tick();
    rst_n = 1'b1;
    repeat (2) tick();

    if (packed_valid !== 1'b0 || o_busy !== 1'b0) record_fail("reset_idle");
    else record_pass("reset_idle");

    for (int i = 0; i < ARRAY_SIZE; i++) row_res_valid[i] = 1'b1;
    tick();
    for (int i = 0; i < ARRAY_SIZE; i++) row_res_valid[i] = 1'b0;

    packed_ready = 1'b0;
    repeat (5) tick();
    if (packed_valid !== 1'b1) record_fail("backpressure_valid_asserts");
    else record_pass("backpressure_valid_asserts");

    packed_ready = 1'b1;
    repeat (20) tick();
    packed_ready = 1'b0;

    if (beat_seen !== 4) begin
      $display("FAIL [beat_count]: beat_seen=%0d expected=4", beat_seen);
      fail_count++;
    end else begin
      record_pass("beat_count_4");
    end

    repeat (4) tick();
    if (packed_valid !== 1'b0 || o_busy !== 1'b0) record_fail("final_idle");
    else record_pass("final_idle");

    beat_seen = 0;
    prev_valid_data = '0;
    for (int i = 0; i < ARRAY_SIZE; i++) begin
      row_res[i] = '0;
      row_res_valid[i] = 1'b1;
    end
    tick();
    for (int i = 0; i < ARRAY_SIZE; i++) row_res_valid[i] = 1'b0;
    repeat (5) tick();
    if (packed_valid !== 1'b1 || packed_data !== '0) record_fail("stale_zero_word_created");
    else record_pass("stale_zero_word_created");

    clear = 1'b1;
    tick();
    clear = 1'b0;
    repeat (2) tick();
    if (packed_valid !== 1'b0 || o_busy !== 1'b0) record_fail("clear_flushes_stale_word");
    else record_pass("clear_flushes_stale_word");

    capture_enable = 1'b0;
    for (int i = 0; i < ARRAY_SIZE; i++) row_res_valid[i] = 1'b1;
    tick();
    for (int i = 0; i < ARRAY_SIZE; i++) row_res_valid[i] = 1'b0;
    repeat (5) tick();
    if (packed_valid !== 1'b0 || o_busy !== 1'b0) record_fail("capture_disabled_ignores_pre_gemm_valid");
    else record_pass("capture_disabled_ignores_pre_gemm_valid");

    expected_base = 16'h6000;
    capture_enable = 1'b1;
    for (int i = 0; i < ARRAY_SIZE; i++) begin
      row_res[i] = 16'h6000 + i;
      row_res_valid[i] = 1'b1;
    end
    tick();
    for (int i = 0; i < ARRAY_SIZE; i++) row_res_valid[i] = 1'b0;
    packed_ready = 1'b1;
    repeat (20) tick();
    packed_ready = 1'b0;

    if (beat_seen !== 4) begin
      $display("FAIL [post_clear_beat_count]: beat_seen=%0d expected=4", beat_seen);
      fail_count++;
    end else begin
      record_pass("post_clear_beat_count_4");
    end

    repeat (4) tick();
    if (packed_valid !== 1'b0 || o_busy !== 1'b0) record_fail("post_clear_final_idle");
    else record_pass("post_clear_final_idle");

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
