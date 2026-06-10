`timescale 1ns / 1ps

module tb_GEMV_top_contract;
  import dtype_pkg::*;
  import vec_core_pkg::*;

  localparam int FMAP_CNT = vec_core_pkg::VecCoreDefaultCfg.fmap_cache_out_cnt;
  localparam int WEIGHT_CNT = vec_core_pkg::VecCoreDefaultCfg.weight_cnt;
  localparam int WEIGHT_W = vec_core_pkg::VecCoreDefaultCfg.weight_width;
  localparam int LANES = vec_core_pkg::VecCoreDefaultCfg.num_gemv_pipeline;
  localparam int BATCH = vec_core_pkg::VecCoreDefaultCfg.gemv_batch;
  localparam int FMAP_W = vec_core_pkg::VecCoreDefaultCfg.fixed_mant_width;
  localparam int OUT_W = FMAP_W + 3;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  logic in_weight_valid_a;
  logic in_weight_valid_b;
  logic in_weight_valid_c;
  logic in_weight_valid_d;
  logic [WEIGHT_W-1:0] in_weight_a[0:WEIGHT_CNT-1];
  logic [WEIGHT_W-1:0] in_weight_b[0:WEIGHT_CNT-1];
  logic [WEIGHT_W-1:0] in_weight_c[0:WEIGHT_CNT-1];
  logic [WEIGHT_W-1:0] in_weight_d[0:WEIGHT_CNT-1];

  logic out_weight_ready_a;
  logic out_weight_ready_b;
  logic out_weight_ready_c;
  logic out_weight_ready_d;

  logic [FMAP_W-1:0] in_fmap_broadcast[0:FMAP_CNT-1];
  logic in_fmap_broadcast_valid;
  logic [16:0] in_num_recur;
  logic [dtype_pkg::Bf16ExpWidth-1:0] in_cached_emax_out[0:FMAP_CNT-1];
  logic in_activated_lane[0:LANES-1];

  logic [OUT_W-1:0] out_final_fmap_a[0:BATCH-1];
  logic [OUT_W-1:0] out_final_fmap_b[0:BATCH-1];
  logic [OUT_W-1:0] out_final_fmap_c[0:BATCH-1];
  logic [OUT_W-1:0] out_final_fmap_d[0:BATCH-1];
  logic out_result_valid_a;
  logic out_result_valid_b;
  logic out_result_valid_c;
  logic out_result_valid_d;

  int pass_count = 0;
  int fail_count = 0;

  always #1.25 clk = ~clk;  // 400 MHz

  GEMV_top #(
      .param(VecCoreDefaultCfg)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .IN_weight_valid_A(in_weight_valid_a),
      .IN_weight_valid_B(in_weight_valid_b),
      .IN_weight_valid_C(in_weight_valid_c),
      .IN_weight_valid_D(in_weight_valid_d),
      .IN_weight_A(in_weight_a),
      .IN_weight_B(in_weight_b),
      .IN_weight_C(in_weight_c),
      .IN_weight_D(in_weight_d),
      .OUT_weight_ready_A(out_weight_ready_a),
      .OUT_weight_ready_B(out_weight_ready_b),
      .OUT_weight_ready_C(out_weight_ready_c),
      .OUT_weight_ready_D(out_weight_ready_d),
      .IN_fmap_broadcast(in_fmap_broadcast),
      .IN_fmap_broadcast_valid(in_fmap_broadcast_valid),
      .IN_num_recur(in_num_recur),
      .IN_cached_emax_out(in_cached_emax_out),
      .IN_activated_lane(in_activated_lane),
      .OUT_final_fmap_A(out_final_fmap_a),
      .OUT_final_fmap_B(out_final_fmap_b),
      .OUT_final_fmap_C(out_final_fmap_c),
      .OUT_final_fmap_D(out_final_fmap_d),
      .OUT_result_valid_A(out_result_valid_a),
      .OUT_result_valid_B(out_result_valid_b),
      .OUT_result_valid_C(out_result_valid_c),
      .OUT_result_valid_D(out_result_valid_d)
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

  task automatic check_known(input string name, input logic got);
    if ($isunknown(got)) begin
      $display("FAIL: %s is unknown", name);
      fail_count++;
    end else begin
      $display("PASS: %s known = %0b", name, got);
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

  task automatic init_inputs;
    in_weight_valid_a = 1'b0;
    in_weight_valid_b = 1'b0;
    in_weight_valid_c = 1'b0;
    in_weight_valid_d = 1'b0;
    in_fmap_broadcast_valid = 1'b0;
    in_num_recur = 17'd3;

    for (int i = 0; i < WEIGHT_CNT; i++) begin
      in_weight_a[i] = WEIGHT_W'(9);  // LUT index 9 => signed INT4 +1
      in_weight_b[i] = WEIGHT_W'(9);
      in_weight_c[i] = WEIGHT_W'(9);
      in_weight_d[i] = WEIGHT_W'(9);
    end

    for (int i = 0; i < FMAP_CNT; i++) begin
      in_fmap_broadcast[i] = FMAP_W'(1);
      in_cached_emax_out[i] = '0;
    end

    for (int lane = 0; lane < LANES; lane++) begin
      in_activated_lane[lane] = 1'b0;
    end
  endtask

  task automatic run_single_batch(input string label);
    int guard;
    int valid_count;

    in_activated_lane[0] = 1'b1;
    in_fmap_broadcast_valid = 1'b1;

    for (int cycle = 0; cycle < 6; cycle++) begin
      in_weight_valid_a = 1'b1;
      tick();
      check_bit($sformatf("%s ready A while active valid", label), out_weight_ready_a, 1'b1);
      check_bit($sformatf("%s ready B disabled lane", label), out_weight_ready_b, 1'b0);
    end

    in_weight_valid_a = 1'b0;
    valid_count = 0;
    for (guard = 0; guard < 80; guard++) begin
      tick();
      if (out_result_valid_a) begin
        valid_count++;
      end
      if (out_result_valid_b || out_result_valid_c || out_result_valid_d) begin
        $display("FAIL: %s inactive lane result valid", label);
        fail_count++;
      end
    end

    if (valid_count != 1) begin
      $display("FAIL: %s expected one result pulse, got %0d", label, valid_count);
      fail_count++;
    end else begin
      $display("PASS: %s one result pulse", label);
      pass_count++;
    end

    in_fmap_broadcast_valid = 1'b0;
    tick();
  endtask

  initial begin
    init_inputs();
    repeat (8) tick();
    check_known("reset ready A", out_weight_ready_a);
    check_bit("reset result valid A", out_result_valid_a, 1'b0);

    rst_n = 1'b1;
    repeat (4) tick();
    check_bit("idle ready A", out_weight_ready_a, 1'b0);

    in_activated_lane[0] = 1'b1;
    in_activated_lane[1] = 1'b0;
    in_weight_valid_a = 1'b1;
    in_weight_valid_b = 1'b1;
    tick();
    check_bit("ready A follows active valid", out_weight_ready_a, 1'b1);
    check_bit("ready B stays low when lane inactive", out_weight_ready_b, 1'b0);
    in_weight_valid_a = 1'b0;
    in_weight_valid_b = 1'b0;

    run_single_batch("batch0");
    run_single_batch("batch1 after fmap valid re-arm");

    repeat (12) begin
      tick();
      check_bit("post batches no duplicate valid", out_result_valid_a, 1'b0);
    end

    finish_check();
  end
endmodule
