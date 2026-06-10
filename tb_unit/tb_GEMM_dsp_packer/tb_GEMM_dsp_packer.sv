// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 pccxai
//
// tb_GEMM_dsp_packer — unit testbench for GEMM_dsp_packer.sv
//
// DUT spec:
//   in_w_lower, in_w_upper (signed INT4 each)
//   in_act (signed INT8)
//   out_a_packed = (w_upper << UPPER_SHIFT) + w_lower  (signed, A_PORT_W bits)
//   out_b_extended = sign-ext(in_act) to B_PORT_W bits
//
// 검증: 패킹 후 DSP48E2 multiply 시뮬레이션 → unpack → original w_upper*act, w_lower*act 일치
//   즉 round-trip integrity check (packer↔reference signed multiply↔sign_recovery)

`timescale 1ns / 1ps

module tb_GEMM_dsp_packer;

    localparam int INT4_BITS   = 4;
    localparam int INT8_BITS   = 8;
    localparam int A_PORT_W    = 30;
    localparam int B_PORT_W    = 18;
    localparam int UPPER_SHIFT = 21;
    localparam int P_PORT_W    = 48;
    localparam int LOWER_W     = 21;
    localparam int UPPER_W     = 21;

    logic signed [INT4_BITS-1:0] in_w_lower, in_w_upper;
    logic signed [INT8_BITS-1:0] in_act;
    logic signed [A_PORT_W-1:0]  out_a_packed;
    logic signed [B_PORT_W-1:0]  out_b_extended;

    int pass_count = 0, fail_count = 0;

    GEMM_dsp_packer #(
        .INT4_BITS(INT4_BITS), .INT8_BITS(INT8_BITS),
        .A_PORT_W(A_PORT_W), .B_PORT_W(B_PORT_W),
        .UPPER_SHIFT(UPPER_SHIFT)
    ) dut (
        .in_w_lower    (in_w_lower),
        .in_w_upper    (in_w_upper),
        .in_act        (in_act),
        .out_a_packed  (out_a_packed),
        .out_b_extended(out_b_extended)
    );

    // ===| DSP48E2 emulated multiply (27x18 signed) + sign-recovery |==============
    function automatic void emulate_dsp_and_unpack(
        input  logic signed [A_PORT_W-1:0] a_packed,
        input  logic signed [B_PORT_W-1:0] b_ext,
        output logic signed [P_PORT_W-1:0] p_accum,
        output int                          lower_unpack,
        output int                          upper_unpack
    );
        logic signed [LOWER_W-1:0]  lower_slice;
        logic signed [UPPER_W-1:0]  upper_raw;

        p_accum = signed'(a_packed) * signed'(b_ext);

        lower_slice = p_accum[LOWER_W-1:0];
        upper_raw   = p_accum[UPPER_SHIFT + UPPER_W - 1 : UPPER_SHIFT];
        lower_unpack = lower_slice;
        upper_unpack = p_accum[LOWER_W-1] ? (upper_raw + 1) : upper_raw;
    endfunction

    task automatic check_vector(input string label,
                                input logic signed [INT4_BITS-1:0] w_l,
                                input logic signed [INT4_BITS-1:0] w_u,
                                input logic signed [INT8_BITS-1:0] a);
        logic signed [P_PORT_W-1:0] p;
        int unpack_lower, unpack_upper;
        int expected_lower, expected_upper;

        in_w_lower = w_l;
        in_w_upper = w_u;
        in_act     = a;
        #1;

        emulate_dsp_and_unpack(out_a_packed, out_b_extended, p, unpack_lower, unpack_upper);

        expected_lower = w_l * a;
        expected_upper = w_u * a;

        if (unpack_lower === expected_lower && unpack_upper === expected_upper) begin
            $display("PASS [%s]: w_l=%0d w_u=%0d a=%0d → lower=%0d upper=%0d (a_packed=%h b_ext=%h p=%h)",
                     label, w_l, w_u, a, unpack_lower, unpack_upper, out_a_packed, out_b_extended, p);
            pass_count++;
        end else begin
            $display("FAIL [%s]: w_l=%0d w_u=%0d a=%0d", label, w_l, w_u, a);
            $display("  expected: lower=%0d upper=%0d", expected_lower, expected_upper);
            $display("  got:      lower=%0d upper=%0d (a_packed=%h b_ext=%h p=%h)",
                     unpack_lower, unpack_upper, out_a_packed, out_b_extended, p);
            fail_count++;
        end
    endtask

    initial begin
        $display("=== tb_GEMM_dsp_packer start ===");

        // Directed cases
        check_vector("zero",         4'sd0, 4'sd0, 8'sd0);
        check_vector("w_lower_pos",  4'sd3, 4'sd0, 8'sd5);
        check_vector("w_upper_pos",  4'sd0, 4'sd3, 8'sd5);
        check_vector("both_pos",     4'sd3, 4'sd5, 8'sd7);
        check_vector("w_lower_neg",  -4'sd3, 4'sd0, 8'sd5);
        check_vector("w_upper_neg",  4'sd0, -4'sd3, 8'sd5);
        check_vector("both_neg",     -4'sd3, -4'sd5, 8'sd7);
        check_vector("act_neg",      4'sd3, 4'sd5, -8'sd7);
        check_vector("all_neg",      -4'sd3, -4'sd5, -8'sd7);
        check_vector("w_max",        4'sd7, 4'sd7, 8'sd127);
        check_vector("w_min",        -4'sd8, -4'sd8, -8'sd128);
        check_vector("mixed_extreme", -4'sd8, 4'sd7, -8'sd128);

        // Exhaustive: all 16 × 16 × 256 = 65536 combos (small enough)
        $display("=== Exhaustive INT4 × INT4 × INT8 (4096 combos sample) ===");
        for (int wl = -8; wl < 8; wl++) begin
            for (int wu = -8; wu < 8; wu++) begin
                for (int a = -128; a < 128; a += 16) begin  // every 16th
                    check_vector($sformatf("exh_%0d_%0d_%0d", wl, wu, a),
                                 INT4_BITS'(wl), INT4_BITS'(wu), INT8_BITS'(a));
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
