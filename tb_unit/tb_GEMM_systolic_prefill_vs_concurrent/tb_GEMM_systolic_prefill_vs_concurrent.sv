`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"
`include "GEMM_Array.svh"

module tb_GEMM_systolic_prefill_vs_concurrent;

  localparam int WEIGHT_CNT = `HP_SINGLE_WIDTH / `INT4_WIDTH;
  localparam int ARRAY_H = `ARRAY_SIZE_H;
  localparam int FMAP_W = `FIXED_MANT_WIDTH;
  localparam int P_W = `DSP48E2_POUT_SIZE;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic i_clear = 1'b0;

  logic global_weight_valid = 1'b0;
  logic [2:0] global_inst = 3'b000;
  logic global_inst_valid = 1'b0;

  logic [FMAP_W-1:0] IN_fmap_broadcast[0:ARRAY_H-1];
  logic IN_fmap_broadcast_valid = 1'b0;
  logic [`BF16_EXP_WIDTH-1:0] IN_cached_emax_out[0:ARRAY_H-1];

  logic [`INT4_WIDTH-1:0] IN_weight_upper[0:WEIGHT_CNT-1];
  logic IN_weight_upper_valid = 1'b0;
  logic IN_weight_upper_ready;
  logic [`INT4_WIDTH-1:0] IN_weight_lower[0:WEIGHT_CNT-1];
  logic IN_weight_lower_valid = 1'b0;
  logic IN_weight_lower_ready;

  logic [P_W-1:0] raw_res_sum[0:ARRAY_H-1];
  logic raw_res_sum_valid[0:ARRAY_H-1];
  logic [`BF16_EXP_WIDTH-1:0] delayed_emax_32[0:ARRAY_H-1];
  logic signed [P_W-1:0] recovered_res_sum[0:ARRAY_H-1];
  logic [`BF16_WIDTH-1:0] norm_res_seq[0:ARRAY_H-1];
  logic norm_res_seq_valid[0:ARRAY_H-1];
  logic [`AXI_STREAM_WIDTH-1:0] packed_data;
  logic packed_valid;
  logic packed_ready = 1'b1;
  logic packed_busy;

  int pass_count = 0;
  int fail_count = 0;

  always #5 clk = ~clk;

  GEMM_systolic_top dut (
      .clk(clk),
      .rst_n(rst_n),
      .i_clear(i_clear),
      .global_weight_valid(global_weight_valid),
      .global_inst(global_inst),
      .global_inst_valid(global_inst_valid),
      .IN_fmap_broadcast(IN_fmap_broadcast),
      .IN_fmap_broadcast_valid(IN_fmap_broadcast_valid),
      .IN_cached_emax_out(IN_cached_emax_out),
      .IN_weight_upper(IN_weight_upper),
      .IN_weight_upper_valid(IN_weight_upper_valid),
      .IN_weight_upper_ready(IN_weight_upper_ready),
      .IN_weight_lower(IN_weight_lower),
      .IN_weight_lower_valid(IN_weight_lower_valid),
      .IN_weight_lower_ready(IN_weight_lower_ready),
      .raw_res_sum(raw_res_sum),
      .raw_res_sum_valid(raw_res_sum_valid),
      .delayed_emax_32(delayed_emax_32)
  );

  genvar gi;
  generate
    for (gi = 0; gi < ARRAY_H; gi++) begin : gen_result_pipe
      GEMM_dual_mac_recover u_recover (
          .in_p_accum(raw_res_sum[gi]),
          .out_sum(recovered_res_sum[gi])
      );

      gemm_result_normalizer u_norm (
          .clk(clk),
          .rst_n(rst_n),
          .clear(1'b0),
          .data_in(recovered_res_sum[gi]),
          .e_max(delayed_emax_32[gi]),
          .valid_in(raw_res_sum_valid[gi]),
          .data_out(norm_res_seq[gi]),
          .valid_out(norm_res_seq_valid[gi])
      );
    end
  endgenerate

  FROM_gemm_result_packer u_packer (
      .clk(clk),
      .rst_n(rst_n),
      .clear(1'b0),
      .capture_enable(1'b1),
      .row_res(norm_res_seq),
      .row_res_valid(norm_res_seq_valid),
      .packed_data(packed_data),
      .packed_valid(packed_valid),
      .packed_ready(packed_ready),
      .o_busy(packed_busy)
  );

  task automatic tick;
    begin
      @(posedge clk);
      #1;
    end
  endtask

  task automatic check(input string name, input bit ok);
    begin
      if (ok) begin
        $display("PASS [%s]", name);
        pass_count++;
      end else begin
        $display("FAIL [%s]", name);
        fail_count++;
      end
    end
  endtask

  function automatic bit any_raw_valid;
    bit anyv;
    begin
      anyv = 1'b0;
      for (int i = 0; i < ARRAY_H; i++) anyv |= raw_res_sum_valid[i];
      return anyv;
    end
  endfunction

  task automatic set_weights(input logic [`INT4_WIDTH-1:0] value);
    begin
      for (int i = 0; i < WEIGHT_CNT; i++) begin
        IN_weight_upper[i] = value;
        IN_weight_lower[i] = value;
      end
    end
  endtask

  task automatic set_fmap(input logic [7:0] low8);
    begin
      for (int i = 0; i < ARRAY_H; i++) begin
        IN_fmap_broadcast[i] = {{(FMAP_W - 8) {1'b0}}, low8};
        IN_cached_emax_out[i] = 8'h8d;
      end
    end
  endtask

  task automatic reset_inputs;
    begin
      global_weight_valid = 1'b0;
      global_inst = 3'b000;
      global_inst_valid = 1'b0;
      IN_fmap_broadcast_valid = 1'b0;
      IN_weight_upper_valid = 1'b0;
      IN_weight_lower_valid = 1'b0;
      set_weights(4'h0);
      set_fmap(8'h00);
    end
  endtask

  task automatic dump_pe_probe(input string label);
    begin
      $display("DIAG %s r00c00 inst=%b ce=%b op=%b wU=%0d wL=%0d a=%h b=%h p=%h pc=%h",
               label,
               dut.u_compute_core.gemm_row_loop[0].gemm_col_loop[0].normal_row.dsp_unit.current_inst,
               dut.u_compute_core.gemm_row_loop[0].gemm_col_loop[0].normal_row.dsp_unit.dsp_ce_p,
               dut.u_compute_core.gemm_row_loop[0].gemm_col_loop[0].normal_row.dsp_unit.dynamic_opmode,
               $signed(dut.u_compute_core.gemm_row_loop[0].gemm_col_loop[0].normal_row.dsp_unit.w_upper_reg),
               $signed(dut.u_compute_core.gemm_row_loop[0].gemm_col_loop[0].normal_row.dsp_unit.w_lower_reg),
               dut.u_compute_core.gemm_row_loop[0].gemm_col_loop[0].normal_row.dsp_unit.a_packed,
               dut.u_compute_core.gemm_row_loop[0].gemm_col_loop[0].normal_row.dsp_unit.b_extended,
               dut.u_compute_core.gemm_row_loop[0].gemm_col_loop[0].normal_row.dsp_unit.p_internal,
               dut.u_compute_core.gemm_V_result_wire[1][0]);
      $display("DIAG %s r15c00 inst=%b ce=%b op=%b wU=%0d wL=%0d a=%h b=%h p=%h pc=%h",
               label,
               dut.u_compute_core.gemm_row_loop[15].gemm_col_loop[0].normal_row.dsp_unit.current_inst,
               dut.u_compute_core.gemm_row_loop[15].gemm_col_loop[0].normal_row.dsp_unit.dsp_ce_p,
               dut.u_compute_core.gemm_row_loop[15].gemm_col_loop[0].normal_row.dsp_unit.dynamic_opmode,
               $signed(dut.u_compute_core.gemm_row_loop[15].gemm_col_loop[0].normal_row.dsp_unit.w_upper_reg),
               $signed(dut.u_compute_core.gemm_row_loop[15].gemm_col_loop[0].normal_row.dsp_unit.w_lower_reg),
               dut.u_compute_core.gemm_row_loop[15].gemm_col_loop[0].normal_row.dsp_unit.a_packed,
               dut.u_compute_core.gemm_row_loop[15].gemm_col_loop[0].normal_row.dsp_unit.b_extended,
               dut.u_compute_core.gemm_row_loop[15].gemm_col_loop[0].normal_row.dsp_unit.p_internal,
               dut.u_compute_core.gemm_V_result_wire[16][0]);
      $display("DIAG %s r16c00 inst=%b ce=%b op=%b wU=%0d wL=%0d a=%h b=%h p=%h pc=%h fabric=%h",
               label,
               dut.u_compute_core.gemm_row_loop[16].gemm_col_loop[0].break_row.dsp_unit_break.current_inst,
               dut.u_compute_core.gemm_row_loop[16].gemm_col_loop[0].break_row.dsp_unit_break.dsp_ce_p,
               dut.u_compute_core.gemm_row_loop[16].gemm_col_loop[0].break_row.dsp_unit_break.dynamic_opmode,
               $signed(dut.u_compute_core.gemm_row_loop[16].gemm_col_loop[0].break_row.dsp_unit_break.w_upper_reg),
               $signed(dut.u_compute_core.gemm_row_loop[16].gemm_col_loop[0].break_row.dsp_unit_break.w_lower_reg),
               dut.u_compute_core.gemm_row_loop[16].gemm_col_loop[0].break_row.dsp_unit_break.a_packed,
               dut.u_compute_core.gemm_row_loop[16].gemm_col_loop[0].break_row.dsp_unit_break.b_extended,
               dut.u_compute_core.gemm_row_loop[16].gemm_col_loop[0].break_row.dsp_unit_break.p_internal,
               dut.u_compute_core.gemm_V_result_wire[17][0],
               dut.u_compute_core.gemm_P_fabric_wire[16][0]);
      $display("DIAG %s r31c00 inst=%b ce=%b op=%b wU=%0d wL=%0d a=%h b=%h pcin=%h p=%h pcout=%h",
               label,
               dut.u_compute_core.gemm_row_loop[31].gemm_col_loop[0].last_row.dsp_unit_last_ROW.current_inst,
               dut.u_compute_core.gemm_row_loop[31].gemm_col_loop[0].last_row.dsp_unit_last_ROW.dsp_ce_p,
               dut.u_compute_core.gemm_row_loop[31].gemm_col_loop[0].last_row.dsp_unit_last_ROW.dynamic_opmode,
               $signed(dut.u_compute_core.gemm_row_loop[31].gemm_col_loop[0].last_row.dsp_unit_last_ROW.w_upper_reg),
               $signed(dut.u_compute_core.gemm_row_loop[31].gemm_col_loop[0].last_row.dsp_unit_last_ROW.w_lower_reg),
               dut.u_compute_core.gemm_row_loop[31].gemm_col_loop[0].last_row.dsp_unit_last_ROW.a_packed,
               dut.u_compute_core.gemm_row_loop[31].gemm_col_loop[0].last_row.dsp_unit_last_ROW.b_extended,
               dut.u_compute_core.gemm_V_result_wire[31][0],
               dut.u_compute_core.gemm_row_loop[31].gemm_col_loop[0].last_row.dsp_unit_last_ROW.gemm_unit_results,
               dut.u_compute_core.gemm_V_result_wire[32][0]);
    end
  endtask

  task automatic soft_clear;
    begin
      i_clear = 1'b1;
      repeat (3) tick();
      i_clear = 1'b0;
      repeat (5) tick();
    end
  endtask

  task automatic prefill_weights(input int cycles, input logic [`INT4_WIDTH-1:0] value);
    begin
      set_weights(value);
      IN_weight_upper_valid = 1'b1;
      IN_weight_lower_valid = 1'b1;
      repeat (cycles) tick();
      IN_weight_upper_valid = 1'b0;
      IN_weight_lower_valid = 1'b0;
      repeat (4) tick();
    end
  endtask

  task automatic drive_fmap_window(input int cycles, input bit concurrent_weights,
                                   output int valid_seen, output int packed_seen,
                                   output bit raw_nonzero, output bit recovered_nonzero,
                                   output bit norm_nonzero, output bit packed_nonzero);
    begin
      valid_seen = 0;
      packed_seen = 0;
      raw_nonzero = 1'b0;
      recovered_nonzero = 1'b0;
      norm_nonzero = 1'b0;
      packed_nonzero = 1'b0;
      set_fmap(8'h40);
      global_inst = 3'b001;
      global_inst_valid = 1'b1;
      IN_fmap_broadcast_valid = 1'b1;
      if (concurrent_weights) begin
        set_weights(4'h1);
        IN_weight_upper_valid = 1'b1;
        IN_weight_lower_valid = 1'b1;
      end
      for (int c = 0; c < cycles; c++) begin
        tick();
        if (any_raw_valid()) begin
          valid_seen++;
          for (int r = 0; r < ARRAY_H; r++) begin
            if (raw_res_sum_valid[r]) begin
              raw_nonzero |= (raw_res_sum[r] != '0);
              recovered_nonzero |= (recovered_res_sum[r] != '0);
            end
          end
        end
        for (int r = 0; r < ARRAY_H; r++) begin
          if (norm_res_seq_valid[r]) norm_nonzero |= (norm_res_seq[r] != '0);
        end
        if (packed_valid && packed_ready) begin
          packed_seen++;
          packed_nonzero |= (packed_data != '0);
        end
        global_inst_valid = 1'b0;
      end
      IN_fmap_broadcast_valid = 1'b0;
      IN_weight_upper_valid = 1'b0;
      IN_weight_lower_valid = 1'b0;
      repeat (96) begin
        tick();
        if (any_raw_valid()) begin
          valid_seen++;
          for (int r = 0; r < ARRAY_H; r++) begin
            if (raw_res_sum_valid[r]) begin
              raw_nonzero |= (raw_res_sum[r] != '0);
              recovered_nonzero |= (recovered_res_sum[r] != '0);
            end
          end
        end
        for (int r = 0; r < ARRAY_H; r++) begin
          if (norm_res_seq_valid[r]) norm_nonzero |= (norm_res_seq[r] != '0);
        end
        if (packed_valid && packed_ready) begin
          packed_seen++;
          packed_nonzero |= (packed_data != '0);
        end
      end
    end
  endtask

  initial begin
    int prefill_valids;
    int concurrent_valids;
    int prefill_packed;
    int concurrent_packed;
    bit prefill_raw_nonzero;
    bit prefill_recovered_nonzero;
    bit prefill_norm_nonzero;
    bit prefill_packed_nonzero;
    bit concurrent_raw_nonzero;
    bit concurrent_recovered_nonzero;
    bit concurrent_norm_nonzero;
    bit concurrent_packed_nonzero;

    $display("=== tb_GEMM_systolic_prefill_vs_concurrent start ===");
    reset_inputs();
    repeat (6) tick();
    rst_n = 1'b1;
    repeat (8) tick();

    soft_clear();
    prefill_weights(96, 4'h1);
    dump_pe_probe("prefill_only_after_weight_prefill");
    drive_fmap_window(96, 1'b0, prefill_valids, prefill_packed, prefill_raw_nonzero,
                      prefill_recovered_nonzero, prefill_norm_nonzero, prefill_packed_nonzero);
    dump_pe_probe("prefill_only_after_compute");
    $display("prefill_only raw_valid_samples=%0d packed_beats=%0d raw_nonzero=%0b recovered_nonzero=%0b norm_nonzero=%0b packed_nonzero=%0b",
             prefill_valids, prefill_packed, prefill_raw_nonzero, prefill_recovered_nonzero,
             prefill_norm_nonzero, prefill_packed_nonzero);

    soft_clear();
    drive_fmap_window(96, 1'b1, concurrent_valids, concurrent_packed, concurrent_raw_nonzero,
                      concurrent_recovered_nonzero, concurrent_norm_nonzero,
                      concurrent_packed_nonzero);
    dump_pe_probe("concurrent_after_compute");
    $display("concurrent raw_valid_samples=%0d packed_beats=%0d raw_nonzero=%0b recovered_nonzero=%0b norm_nonzero=%0b packed_nonzero=%0b",
             concurrent_valids, concurrent_packed, concurrent_raw_nonzero,
             concurrent_recovered_nonzero, concurrent_norm_nonzero, concurrent_packed_nonzero);

    check("prefill_only_produces_raw_valid", prefill_valids > 0);
    check("prefill_only_raw_nonzero", prefill_raw_nonzero);
    check("prefill_only_recovered_nonzero", prefill_recovered_nonzero);
    check("prefill_only_norm_nonzero", prefill_norm_nonzero);
    check("prefill_only_produces_packed_beats", prefill_packed >= 4);
    check("prefill_only_packed_nonzero", prefill_packed_nonzero);
    check("concurrent_produces_raw_valid", concurrent_valids > 0);
    check("concurrent_raw_nonzero", concurrent_raw_nonzero);
    check("concurrent_recovered_nonzero", concurrent_recovered_nonzero);
    check("concurrent_norm_nonzero", concurrent_norm_nonzero);
    check("concurrent_produces_packed_beats", concurrent_packed >= 4);
    check("concurrent_packed_nonzero", concurrent_packed_nonzero);

    $display("");
    $display("=== Summary ===");
    $display("PASS: %0d / %0d", pass_count, pass_count + fail_count);
    $display("FAIL: %0d", fail_count);
    if (fail_count == 0) $display("OVERALL: PASS");
    else                 $display("OVERALL: FAIL");
    $finish;
  end

endmodule
