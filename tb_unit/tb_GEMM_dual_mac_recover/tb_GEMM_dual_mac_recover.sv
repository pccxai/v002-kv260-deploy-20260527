// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 pccxai
//
// tb_GEMM_dual_mac_recover
//
// Checks that the packed W4A8 dual-MAC DSP product is converted back into the
// mathematical lower+upper sum before the GEMM result normalizer consumes it.

`timescale 1ns / 1ps

module tb_GEMM_dual_mac_recover;

  localparam int P_PORT_W = 48;
  localparam int UPPER_SHIFT = 21;

  logic signed [P_PORT_W-1:0] in_p_accum;
  logic signed [P_PORT_W-1:0] out_sum;

  int pass_count = 0;
  int fail_count = 0;

  GEMM_dual_mac_recover #(
      .P_PORT_W   (P_PORT_W),
      .UPPER_SHIFT(UPPER_SHIFT),
      .LOWER_W    (UPPER_SHIFT),
      .UPPER_W    (21)
  ) dut (
      .in_p_accum(in_p_accum),
      .out_sum   (out_sum)
  );

  function automatic logic signed [P_PORT_W-1:0] packed_product(
      input int lower_w,
      input int upper_w,
      input int act
  );
    longint signed a_packed;
    longint signed p;
    begin
      a_packed = (longint'(upper_w) <<< UPPER_SHIFT) + longint'(lower_w);
      p = a_packed * longint'(act);
      packed_product = p[P_PORT_W-1:0];
    end
  endfunction

  task automatic check_vector(
      input string label,
      input int lower_w,
      input int upper_w,
      input int act
  );
    longint signed expected;
    begin
      in_p_accum = packed_product(lower_w, upper_w, act);
      expected = (lower_w * act) + (upper_w * act);
      #1;

      if ($signed(out_sum) == expected) begin
        $display(
            "PASS [%s]: lower_w=%0d upper_w=%0d act=%0d sum=%0d p=%h",
            label, lower_w, upper_w, act, $signed(out_sum), in_p_accum
        );
        pass_count++;
      end else begin
        $display("FAIL [%s]: lower_w=%0d upper_w=%0d act=%0d p=%h",
                 label, lower_w, upper_w, act, in_p_accum);
        $display("  expected sum=%0d got=%0d", expected, $signed(out_sum));
        fail_count++;
      end
    end
  endtask

  initial begin
    $display("=== tb_GEMM_dual_mac_recover start ===");

    check_vector("zero", 0, 0, 0);
    check_vector("lower_only", 3, 0, 5);
    check_vector("upper_only", 0, 3, 5);
    check_vector("both_pos", 3, 5, 7);
    check_vector("lower_neg_borrow", -3, 5, 7);
    check_vector("upper_neg", 3, -5, 7);
    check_vector("act_neg", 3, 5, -7);
    check_vector("all_neg", -3, -5, -7);
    check_vector("max_pos", 7, 7, 127);
    check_vector("min_neg", -8, -8, -128);
    check_vector("mixed_extreme", -8, 7, -128);

    for (int lower_w = -8; lower_w < 8; lower_w++) begin
      for (int upper_w = -8; upper_w < 8; upper_w++) begin
        for (int act = -128; act < 128; act += 17) begin
          check_vector($sformatf("sweep_%0d_%0d_%0d", lower_w, upper_w, act),
                       lower_w, upper_w, act);
        end
      end
    end

    $display("");
    $display("=== Summary ===");
    $display("PASS: %0d / %0d", pass_count, pass_count + fail_count);
    $display("FAIL: %0d", fail_count);
    if (fail_count == 0)
      $display("OVERALL: PASS");
    else
      $display("OVERALL: FAIL");
    $finish;
  end

endmodule
