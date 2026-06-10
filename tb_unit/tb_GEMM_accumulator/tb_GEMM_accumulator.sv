// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 pccxai
//
// tb_GEMM_accumulator — DSP48E2 ALU-only mode (P = P + PCIN) accumulator.
//
// DUT spec:
//   OPMODE   = 9'b00_001_00_10  (W=0, Z=PCIN, Y=0, X=P) -> ALU = P + PCIN
//   USE_MULT = "NONE"
//   PREG     = 1   (1-cycle P register, latency 1)
//   CEP      = i_valid
//   RSTP     = i_clear || ~rst_n  (sync)
//
// Driver rules:
//   - Drive PCIN and i_valid before #1, then @(posedge clk), then #1 to sample P.
//   - Allow extra idle cycle between RSTP transition and first valid edge
//     to avoid any propagation race in the simulation model.

`timescale 1ns / 1ps

module tb_GEMM_accumulator;

    logic clk = 0;
    logic rst_n = 0;
    logic i_clear = 0;
    logic i_valid = 0;
    logic [47:0] PCIN = 0;
    logic [47:0] gemm_ACC_result;

    always #5 clk = ~clk;

    int pass_count = 0, fail_count = 0;

    GEMM_accumulator dut (
        .clk(clk), .rst_n(rst_n),
        .i_clear(i_clear), .i_valid(i_valid),
        .PCIN(PCIN),
        .gemm_ACC_result(gemm_ACC_result)
    );

    // Drive an accumulator step: hold PCIN/valid stable for a full cycle, then sample
    task automatic step_drive(input logic [47:0] pcin_val, input logic valid_val);
        PCIN    = pcin_val;
        i_valid = valid_val;
        #1;
        @(posedge clk);
    endtask

    task automatic check(input string label, input logic [47:0] expected);
        #1;
        if (gemm_ACC_result === expected) begin
            $display("PASS [%s]: P=%0d (h%h)", label, $signed(gemm_ACC_result), gemm_ACC_result);
            pass_count++;
        end else begin
            $display("FAIL [%s]: expected=%0d (h%h)  got=%0d (h%h)",
                     label, $signed(expected), expected, $signed(gemm_ACC_result), gemm_ACC_result);
            fail_count++;
        end
    endtask

    initial begin
        $display("=== tb_GEMM_accumulator start ===");

        // Reset for several cycles
        rst_n = 0; i_clear = 0; i_valid = 0; PCIN = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        // Pulse iclear once to fully prime the DSP48E2 P register sync clear path
        repeat (2) @(posedge clk);
        i_clear = 1; #1; @(posedge clk);
        i_clear = 0; #1; @(posedge clk);
        repeat (2) @(posedge clk);
        check("after_reset", 48'd0);

        // Test 1: single accumulate, P = 0 + 10 = 10
        step_drive(48'd10, 1'b1);
        // After this edge: ALU=0+10=10 sampled into P. P_out=10 after edge.
        step_drive(48'd0, 1'b0);  // hold; let P appear stable
        check("single_add_10", 48'd10);

        // Test 2: chained accumulates 1..5 starting from P=10
        // Expected: 10 -> 11 -> 13 -> 16 -> 20 -> 25
        step_drive(48'd1, 1'b1);
        step_drive(48'd2, 1'b1);
        step_drive(48'd3, 1'b1);
        step_drive(48'd4, 1'b1);
        step_drive(48'd5, 1'b1);
        step_drive(48'd0, 1'b0);  // disable + hold
        check("after_1_2_3_4_5", 48'd25);

        // Test 3: hold (i_valid=0) keeps P
        step_drive(48'd99, 1'b0);
        step_drive(48'd0,  1'b0);
        check("hold_no_valid", 48'd25);

        // Test 4: i_clear pulse resets P to 0
        i_clear = 1; #1; @(posedge clk);
        i_clear = 0; #1; @(posedge clk);
        check("after_iclear", 48'd0);

        // Test 5: negative accumulates
        step_drive(-48'sd100, 1'b1);
        step_drive(-48'sd50,  1'b1);
        step_drive(48'd0,     1'b0);
        check("neg_neg_sum_n150", -48'sd150);

        // Test 6: positive followed by negative, with iclear in between
        i_clear = 1; #1; @(posedge clk);
        i_clear = 0; #1; @(posedge clk);
        step_drive(48'sd100,  1'b1);
        step_drive(-48'sd30,  1'b1);
        step_drive(48'd0,     1'b0);
        check("100_minus30_pos70", 48'sd70);

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
