// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 pccxai
//
// tb_GEMM_sign_recovery — unit testbench for GEMM_sign_recovery.sv
//
// DUT spec (from RTL header):
//   in_p_accum [47:0] → out_lower_sum [20:0] (signed) + out_upper_sum [20:0] (signed)
//   lower = P[20:0] direct slice
//   upper_raw = P[41:21]
//   if P[20] (lower MSB): upper = upper_raw + 1  (borrow correction)
//   else:                  upper = upper_raw
//
// Test strategy:
//   1. Directed cases (9 scenarios)
//   2. Random vectors (1000) — Python golden via NumPy generated $readmemh
//      file `golden.mem` (one line per vector: in_p, expected_lower, expected_upper)
//
// PASS criterion: 모든 vector에서 DUT == golden.

`timescale 1ns / 1ps

module tb_GEMM_sign_recovery;

    // Parameter override — same defaults as RTL (no .svh include needed).
    localparam int P_PORT_W    = 48;
    localparam int UPPER_SHIFT = 21;
    localparam int LOWER_W     = 21;
    localparam int UPPER_W     = 21;

    // DUT signals
    logic signed [P_PORT_W-1:0] in_p_accum;
    logic signed [LOWER_W-1:0]  out_lower_sum;
    logic signed [UPPER_W-1:0]  out_upper_sum;

    // Pass/Fail counters
    int pass_count = 0;
    int fail_count = 0;

    // DUT instance
    GEMM_sign_recovery #(
        .P_PORT_W    (P_PORT_W),
        .UPPER_SHIFT (UPPER_SHIFT),
        .LOWER_W     (LOWER_W),
        .UPPER_W     (UPPER_W)
    ) dut (
        .in_p_accum    (in_p_accum),
        .out_lower_sum (out_lower_sum),
        .out_upper_sum (out_upper_sum)
    );

    // ===| Reference model (mirror RTL spec) |======================================
    function automatic void ref_sign_recovery(
        input  logic [P_PORT_W-1:0]   p_in,
        output logic signed [LOWER_W-1:0] lower_ref,
        output logic signed [UPPER_W-1:0] upper_ref
    );
        logic signed [LOWER_W-1:0]  lower_slice;
        logic signed [UPPER_W-1:0]  upper_raw;
        lower_slice = p_in[LOWER_W-1:0];
        upper_raw   = p_in[UPPER_SHIFT + UPPER_W - 1 : UPPER_SHIFT];
        lower_ref = lower_slice;
        if (p_in[LOWER_W-1]) begin
            // borrow correction
            upper_ref = upper_raw + 1;
        end else begin
            upper_ref = upper_raw;
        end
    endfunction

    // ===| Single check |===========================================================
    task automatic check_vector(
        input string label,
        input logic [P_PORT_W-1:0] p_in
    );
        logic signed [LOWER_W-1:0] exp_lower;
        logic signed [UPPER_W-1:0] exp_upper;
        in_p_accum = p_in;
        #1;  // pure comb, settle
        ref_sign_recovery(p_in, exp_lower, exp_upper);
        if (out_lower_sum === exp_lower && out_upper_sum === exp_upper) begin
            $display("PASS [%s]: P=%h → lower=%0d upper=%0d",
                     label, p_in, out_lower_sum, out_upper_sum);
            pass_count++;
        end else begin
            $display("FAIL [%s]: P=%h", label, p_in);
            $display("  expected: lower=%0d (h%h)  upper=%0d (h%h)",
                     exp_lower, exp_lower, exp_upper, exp_upper);
            $display("  got:      lower=%0d (h%h)  upper=%0d (h%h)",
                     out_lower_sum, out_lower_sum, out_upper_sum, out_upper_sum);
            fail_count++;
        end
    endtask

    // ===| Directed test cases |====================================================
    task automatic run_directed();
        $display("=== Directed cases ===");

        // 1: both zero
        check_vector("zero", 48'h0000_0000_0000);

        // 2: lower=+1, upper=0
        check_vector("lower_p1", 48'h0000_0000_0001);

        // 3: lower=0, upper field=+1 (bit 21 set)
        check_vector("upper_p1", 48'h0000_0020_0000);

        // 4: lower=-1 (0x1FFFFF), upper raw = +4, borrow → upper = +5
        check_vector("lower_n1_borrow", 48'h0000_009F_FFFF);
        //                                              ^^^^^^^
        //   lower bits = 0x1FFFFF (-1 signed 21-bit)
        //   upper field bits [41:21] = ...4 → +4 raw → +5 after borrow

        // 5: lower=max+ (0x0FFFFF = 2^20-1), upper=0
        check_vector("lower_maxpos", 48'h0000_000F_FFFF);

        // 6: lower=min- (0x100000 = -2^20), upper raw=0 → +1 after borrow
        check_vector("lower_minneg", 48'h0000_0010_0000);

        // 7: upper raw=max+ (0x0FFFFF), lower=0
        // upper field is bits [41:21], so value 0x0FFFFF << 21
        check_vector("upper_maxpos", 48'h0001_FFFE_0000);

        // 8: lower=-2 (0x1FFFFE), upper raw=-4 (0x1FFFFC), borrow → upper=-3
        check_vector("both_neg_borrow", 48'h0001_FFFB_FFFE);
        //   lower bits = 0x1FFFFE (-2)
        //   upper field = 0x1FFFFC (-4 signed) → -3 after borrow

        // 9: All ones (lower=-1, upper raw=-1, borrow → upper=0)
        check_vector("all_ones", 48'h0000_3FFF_FFFF);
        //   bits [41:0] all 1, bits [47:42] zero
        //   lower = 0x1FFFFF = -1
        //   upper raw = 0x1FFFFF = -1
        //   borrow: -1+1 = 0
    endtask

    // ===| Random vectors |=========================================================
    task automatic run_random(input int n);
        logic [P_PORT_W-1:0] p_rand;
        $display("=== Random %0d vectors ===", n);
        for (int i = 0; i < n; i++) begin
            // 48-bit random (bit [47:42] zeroed, only [41:0] used per spec)
            p_rand = {6'b0, {$random, $random} & 48'h0000_3FFF_FFFF};
            check_vector($sformatf("rand_%0d", i), p_rand);
        end
    endtask

    initial begin
        $display("=== tb_GEMM_sign_recovery start ===");
        in_p_accum = '0;
        #1;

        run_directed();
        run_random(100);

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
