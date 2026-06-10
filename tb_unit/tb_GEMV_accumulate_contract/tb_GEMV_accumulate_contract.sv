`timescale 1ns / 1ps

module tb_GEMV_accumulate_contract;
  import dtype_pkg::*;
  import vec_core_pkg::*;

  localparam int W = dtype_pkg::FixedMantWidth + 3;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [W-1:0] in_reduction_result;
  logic init;
  logic in_valid;
  logic [16:0] in_num_recur;
  logic [W-1:0] out_vec[0:VecCoreDefaultCfg.gemv_batch-1];
  logic out_acc_valid;

  int pass_count = 0;
  int fail_count = 0;

  always #1.25 clk = ~clk;  // 400 MHz

  GEMV_accumulate dut (
      .clk(clk),
      .rst_n(rst_n),
      .IN_reduction_result(in_reduction_result),
      .init(init),
      .IN_valid(in_valid),
      .IN_num_recur(in_num_recur),
      .OUT_GEMV_result_vector(out_vec),
      .OUT_acc_valid(out_acc_valid)
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

  initial begin
    init = 1'b0;
    in_valid = 1'b0;
    in_num_recur = '0;
    in_reduction_result = '0;

    repeat (4) tick();
    check_bit("reset holds OUT_acc_valid low", out_acc_valid, 1'b0);

    rst_n = 1'b1;
    repeat (4) begin
      tick();
      check_bit("idle before init keeps OUT_acc_valid low", out_acc_valid, 1'b0);
    end

    init = 1'b1;
    in_num_recur = 17'd4;
    tick();
    init = 1'b0;
    in_num_recur = '0;
    check_bit("init cycle does not complete immediately", out_acc_valid, 1'b0);

    for (int i = 0; i < 4; i++) begin
      in_valid = 1'b1;
      in_reduction_result = W'(i + 1);
      tick();
      check_bit("valid input cycle does not assert completion", out_acc_valid, 1'b0);
    end
    in_valid = 1'b0;
    in_reduction_result = '0;

    tick();
    check_bit("completion pulses once after requested recurrence count drains", out_acc_valid, 1'b1);
    check_word("result vector[0]", out_vec[0], W'(1));
    check_word("result vector[1]", out_vec[1], W'(2));
    check_word("result vector[2]", out_vec[2], W'(3));
    check_word("result vector[3]", out_vec[3], W'(4));

    repeat (4) begin
      tick();
      check_bit("post-completion idle keeps OUT_acc_valid low", out_acc_valid, 1'b0);
    end

    finish_check();
  end
endmodule
