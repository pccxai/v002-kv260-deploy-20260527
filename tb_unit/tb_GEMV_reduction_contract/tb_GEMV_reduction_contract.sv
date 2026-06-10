`timescale 1ns / 1ps

module tb_GEMV_reduction_contract;
  import dtype_pkg::*;
  import vec_core_pkg::*;

  localparam int W = dtype_pkg::FixedMantWidth + 3;
  localparam int REDUCTION_LATENCY = 6;
  localparam int LANE_CNT = vec_core_pkg::VecCoreDefaultCfg.fmap_cache_out_cnt;
  localparam int WEIGHT_CNT = vec_core_pkg::VecCoreDefaultCfg.weight_cnt;
  localparam int WEIGHT_W = vec_core_pkg::VecCoreDefaultCfg.weight_width;
  localparam int LUT_DEPTH = 1 << WEIGHT_W;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic in_is_lane_active;
  logic in_valid;
  logic signed [W-1:0] in_fmap_lut[0:LANE_CNT-1][0:LUT_DEPTH-1];
  logic [WEIGHT_W-1:0] in_weight[0:WEIGHT_CNT-1];

  logic [W-1:0] out_reduction_result;
  logic out_reduction_res_valid;

  int pass_count = 0;
  int fail_count = 0;

  always #1.25 clk = ~clk;  // 400 MHz

  GEMV_reduction #(
      .param(VecCoreDefaultCfg),
      .REDUCTION_LATENCY(REDUCTION_LATENCY)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .IN_is_lane_active(in_is_lane_active),
      .IN_valid(in_valid),
      .IN_fmap_LUT(in_fmap_lut),
      .IN_weight(in_weight),
      .OUT_reduction_result(out_reduction_result),
      .OUT_reduction_res_valid(out_reduction_res_valid)
  );

  task automatic tick;
    @(posedge clk);
    #0.1;
  endtask

  task automatic check_bit(input string name, input logic got, input logic exp);
    if (got !== exp) begin
      $display("FAIL: %s got=%0b exp=%0b", name, got, exp);
      fail_count++;
    end else begin
      $display("PASS: %s = %0b", name, got);
      pass_count++;
    end
  endtask

  task automatic check_word(input string name, input logic [W-1:0] got, input logic [W-1:0] exp);
    if (got !== exp) begin
      $display("FAIL: %s got=0x%0h exp=0x%0h", name, got, exp);
      fail_count++;
    end else begin
      $display("PASS: %s = 0x%0h", name, got);
      pass_count++;
    end
  endtask

  task automatic finish_check;
    $display("PASS: %0d / %0d FAIL: %0d", pass_count, pass_count + fail_count, fail_count);
    if (fail_count == 0) begin
      $display("OVERALL: PASS");
    end else begin
      $display("OVERALL: FAIL");
    end
    $finish;
  endtask

  task automatic init_lut;
    for (int lane = 0; lane < LANE_CNT; lane++) begin
      for (int idx = 0; idx < LUT_DEPTH; idx++) begin
        in_fmap_lut[lane][idx] = W'((idx * 100) + lane + 1);
      end
    end
  endtask

  task automatic set_weight_pattern(input int pattern);
    for (int i = 0; i < WEIGHT_CNT; i++) begin
      case (pattern)
        0: in_weight[i] = WEIGHT_W'(i % 4);
        1: in_weight[i] = WEIGHT_W'(1);
        default: in_weight[i] = '0;
      endcase
    end
  endtask

  task automatic set_signed_lut_pattern;
    for (int lane = 0; lane < LANE_CNT; lane++) begin
      for (int idx = 0; idx < LUT_DEPTH; idx++) begin
        if ((lane + idx) % 3 == 0) begin
          in_fmap_lut[lane][idx] = -W'((lane % 5) + idx + 1);
        end else begin
          in_fmap_lut[lane][idx] = W'((lane % 7) + idx + 1);
        end
      end
    end
  endtask

  function automatic logic [W-1:0] expected_sum_from_weights;
    longint signed acc;
    begin
      acc = 0;
      for (int lane = 0; lane < LANE_CNT; lane++) begin
        acc += $signed(in_fmap_lut[lane][in_weight[lane]]);
      end
      expected_sum_from_weights = W'(acc);
    end
  endfunction

  task automatic expect_no_valid_for(input string label, input int cycles);
    for (int i = 0; i < cycles; i++) begin
      tick();
      check_bit(label, out_reduction_res_valid, 1'b0);
    end
  endtask

  task automatic pulse_input(input string label, input logic active, input logic [W-1:0] exp);
    int guard;
    in_valid = 1'b1;
    in_is_lane_active = active;
    tick();
    check_bit($sformatf("%s launch cycle valid low", label), out_reduction_res_valid, 1'b0);

    in_valid = 1'b0;
    in_is_lane_active = 1'b0;
    guard = 0;
    while (!out_reduction_res_valid && guard < REDUCTION_LATENCY + 3) begin
      tick();
      guard++;
    end
    if (active) begin
      check_bit($sformatf("%s output valid", label), out_reduction_res_valid, 1'b1);
      check_word($sformatf("%s reduction result", label), out_reduction_result, exp);
    end else begin
      check_bit($sformatf("%s inactive lane suppresses valid", label), out_reduction_res_valid, 1'b0);
    end
  endtask

  initial begin
    in_is_lane_active = 1'b0;
    in_valid = 1'b0;
    init_lut();
    set_weight_pattern(0);

    repeat (50) tick();
    check_bit("reset holds OUT_reduction_res_valid low", out_reduction_res_valid, 1'b0);
    check_word("reset clears OUT_reduction_result", out_reduction_result, '0);

    rst_n = 1'b1;
    expect_no_valid_for("idle after reset keeps valid low", 6);

    pulse_input("inactive valid pulse", 1'b0, '0);
    expect_no_valid_for("post-inactive idle keeps valid low", 3);

    set_weight_pattern(0);
    pulse_input("deterministic pattern0", 1'b1, expected_sum_from_weights());
    expect_no_valid_for("pattern0 idle has no duplicate valid", 6);

    set_weight_pattern(1);
    pulse_input("deterministic pattern1 after idle gap", 1'b1, expected_sum_from_weights());
    expect_no_valid_for("pattern1 idle has no duplicate valid", 8);

    set_signed_lut_pattern();
    set_weight_pattern(0);
    pulse_input("signed mixed LUT reduction", 1'b1, expected_sum_from_weights());
    expect_no_valid_for("signed mixed LUT idle has no duplicate valid", 8);

    finish_check();
  end
endmodule
