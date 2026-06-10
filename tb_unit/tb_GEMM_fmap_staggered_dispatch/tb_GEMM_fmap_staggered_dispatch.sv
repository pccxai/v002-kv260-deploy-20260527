// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 pccxai
//
// tb_GEMM_fmap_staggered_dispatch — diagonal stagger delay line for fmap broadcast.
//
// DUT spec:
//   array_size = 32 columns
//   Col[c] delays fmap by (c+1) cycles total (col 0 = 1-stage register)
//   row_data[c]/row_valid[c]/row_inst[c]/row_inst_valid[c] = staggered output
//
// Test strategy:
//   1. Inject sentinel pattern at t=0: fmap_in[c] = c (column index), fmap_valid=1
//   2. Hold a few cycles, then deassert valid
//   3. Track each column's row_data/row_valid: column c should see the sentinel
//      (c+1) cycles after injection.
//   4. Verify monotonic stagger: col 31 emits 31 cycles later than col 0.

`timescale 1ns / 1ps

module tb_GEMM_fmap_staggered_dispatch;

    localparam int FMAP_W     = 27;
    localparam int ARRAY_SIZE = 32;
    localparam int FMAP_OUT_W = 30;

    logic clk = 0;
    logic rst_n = 0;
    logic [FMAP_W-1:0]   fmap_in   [0:ARRAY_SIZE-1];
    logic                fmap_valid;
    logic [2:0]          global_inst;
    logic                global_inst_valid;
    logic [FMAP_OUT_W-1:0] row_data      [0:ARRAY_SIZE-1];
    logic                  row_valid     [0:ARRAY_SIZE-1];
    logic [2:0]            row_inst      [0:ARRAY_SIZE-1];
    logic                  row_inst_valid[0:ARRAY_SIZE-1];

    always #5 clk = ~clk;  // 100 MHz

    int pass_count = 0, fail_count = 0;

    // Cycle counter (always_ff is fine since cycle is only driven here)
    int cycle = 0;

    GEMM_fmap_staggered_dispatch #(
        .fmap_width    (FMAP_W),
        .array_size    (ARRAY_SIZE),
        .fmap_out_width(FMAP_OUT_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .fmap_in(fmap_in), .fmap_valid(fmap_valid),
        .global_inst(global_inst), .global_inst_valid(global_inst_valid),
        .row_data(row_data), .row_valid(row_valid),
        .row_inst(row_inst), .row_inst_valid(row_inst_valid)
    );

    always_ff @(posedge clk) cycle <= cycle + 1;

    // Track per-column emission cycle (first non-zero row_valid)
    int emit_cycle [0:ARRAY_SIZE-1];
    initial for (int c = 0; c < ARRAY_SIZE; c++) emit_cycle[c] = -1;

    always @(posedge clk) begin
        for (int c = 0; c < ARRAY_SIZE; c++) begin
            if (row_valid[c] && emit_cycle[c] == -1) begin
                emit_cycle[c] = cycle;
                $display("  col %0d emit at cycle %0d, row_data=%0d (expected sentinel=%0d)",
                         c, cycle, row_data[c], c);
                if (row_data[c] == c)
                    pass_count++;
                else begin
                    $display("    DATA MISMATCH: got %0d, expected %0d", row_data[c], c);
                    fail_count++;
                end
            end
        end
    end

    initial begin
        $display("=== tb_GEMM_fmap_staggered_dispatch start ===");
        // Init
        for (int c = 0; c < ARRAY_SIZE; c++) fmap_in[c] = '0;
        fmap_valid = 0;
        global_inst = 3'd5;
        global_inst_valid = 0;

        // Reset
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Inject sentinel at t (cycle ~5): fmap_in[c] = c
        for (int c = 0; c < ARRAY_SIZE; c++) fmap_in[c] = FMAP_W'(c);
        fmap_valid = 1;
        global_inst_valid = 1;
        @(posedge clk);
        // Deassert after 1 cycle injection
        fmap_valid = 0;
        global_inst_valid = 0;
        for (int c = 0; c < ARRAY_SIZE; c++) fmap_in[c] = '0;

        // Wait for all 32 columns to emit (max delay = 32+ cycles)
        repeat (60) @(posedge clk);

        // Final check — verify stagger pattern (col c emits at cycle c0 + c)
        $display("");
        $display("=== Stagger pattern check ===");
        begin : stagger_check
            int base_cycle;
            int expected_cycle;
            base_cycle = emit_cycle[0];
            if (base_cycle < 0) begin
                $display("FAIL: col 0 never emitted");
                fail_count++;
            end else begin
                for (int c = 1; c < ARRAY_SIZE; c++) begin
                    expected_cycle = base_cycle + c;
                    if (emit_cycle[c] == expected_cycle) begin
                        pass_count++;
                    end else begin
                        $display("FAIL stagger col %0d: expected cycle %0d, got %0d",
                                 c, expected_cycle, emit_cycle[c]);
                        fail_count++;
                    end
                end  // for
                $display("Stagger check loop done");
            end  // else
        end  // stagger_check

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
