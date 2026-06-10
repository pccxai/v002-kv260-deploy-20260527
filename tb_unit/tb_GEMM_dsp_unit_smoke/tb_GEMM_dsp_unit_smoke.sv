`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"

module tb_GEMM_dsp_unit_smoke;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic i_clear = 1'b0;
  logic i_valid = 1'b0;
  logic i_weight_valid = 1'b0;
  logic o_valid;
  logic [3:0] in_H_upper = 4'd0;
  logic [3:0] out_H_upper;
  logic [3:0] in_H_lower = 4'd0;
  logic [3:0] out_H_lower;
  logic [7:0] in_V = 8'd0;
  logic [`DEVICE_DSP_B_WIDTH-1:0] BCIN_in = '0;
  logic [`DEVICE_DSP_B_WIDTH-1:0] BCOUT_out;
  logic [2:0] instruction_in_V = 3'b000;
  logic [2:0] instruction_out_V;
  logic inst_valid_in_V = 1'b0;
  logic inst_valid_out_V;
  logic [`DSP48E2_POUT_SIZE-1:0] V_result_in = '0;
  logic [`DSP48E2_POUT_SIZE-1:0] V_result_out;
  logic [`DSP48E2_POUT_SIZE-1:0] P_fabric_out;

  logic last_o_valid;
  logic [3:0] last_out_H_upper;
  logic [3:0] last_out_H_lower;
  logic [`DEVICE_DSP_B_WIDTH-1:0] last_BCOUT_out;
  logic [2:0] last_instruction_out_V;
  logic last_inst_valid_out_V;
  logic [`DSP48E2_POUT_SIZE-1:0] last_V_result_out;
  logic [`DSP48E2_POUT_SIZE-1:0] last_gemm_unit_results;

  int pass_count = 0;
  int fail_count = 0;
  bit mid_arith_nonzero;
  bit last_arith_nonzero;

  always #5 clk = ~clk;

  GEMM_dsp_unit #(.IS_TOP_ROW(1)) dut_mid (
      .clk(clk),
      .rst_n(rst_n),
      .i_clear(i_clear),
      .i_valid(i_valid),
      .i_weight_valid(i_weight_valid),
      .o_valid(o_valid),
      .in_H_upper(in_H_upper),
      .out_H_upper(out_H_upper),
      .in_H_lower(in_H_lower),
      .out_H_lower(out_H_lower),
      .in_V(in_V),
      .BCIN_in(BCIN_in),
      .BCOUT_out(BCOUT_out),
      .instruction_in_V(instruction_in_V),
      .instruction_out_V(instruction_out_V),
      .inst_valid_in_V(inst_valid_in_V),
      .inst_valid_out_V(inst_valid_out_V),
      .V_result_in(V_result_in),
      .V_result_out(V_result_out),
      .P_fabric_out(P_fabric_out)
  );

  GEMM_dsp_unit_last_ROW #(.IS_TOP_ROW(1)) dut_last (
      .clk(clk),
      .rst_n(rst_n),
      .i_clear(i_clear),
      .i_valid(i_valid),
      .i_weight_valid(i_weight_valid),
      .inst_valid_in_V(inst_valid_in_V),
      .o_valid(last_o_valid),
      .in_H_upper(in_H_upper),
      .out_H_upper(last_out_H_upper),
      .in_H_lower(in_H_lower),
      .out_H_lower(last_out_H_lower),
      .in_V(in_V),
      .BCIN_in(BCIN_in),
      .BCOUT_out(last_BCOUT_out),
      .instruction_in_V(instruction_in_V),
      .instruction_out_V(last_instruction_out_V),
      .inst_valid_out_V(last_inst_valid_out_V),
      .V_result_in(V_result_in),
      .V_result_out(last_V_result_out),
      .gemm_unit_results(last_gemm_unit_results)
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

  initial begin
    $display("=== tb_GEMM_dsp_unit_smoke start ===");
    repeat (8) tick();
    rst_n = 1'b1;
    repeat (4) tick();

    check("reset_o_valid_mid", o_valid === 1'b0);
    check("reset_o_valid_last", last_o_valid === 1'b0);

    in_H_upper = 4'ha;
    in_H_lower = 4'h3;
    i_weight_valid = 1'b1;
    tick();
    i_weight_valid = 1'b0;
    check("mid_weight_shift", out_H_upper === 4'ha && out_H_lower === 4'h3);
    check("last_weight_shift", last_out_H_upper === 4'ha && last_out_H_lower === 4'h3);

    instruction_in_V = 3'b101;
    inst_valid_in_V = 1'b1;
    tick();
    inst_valid_in_V = 1'b0;
    check("mid_instruction_pipe", instruction_out_V === 3'b101 && inst_valid_out_V === 1'b1);
    check("last_instruction_pipe", last_instruction_out_V === 3'b101 && last_inst_valid_out_V === 1'b1);

    in_V = 8'sd7;
    i_valid = 1'b1;
    tick();
    check("mid_o_valid_one_cycle", o_valid === 1'b1);
    check("last_o_valid_one_cycle", last_o_valid === 1'b1);
    i_valid = 1'b0;
    tick();
    check("mid_o_valid_drops", o_valid === 1'b0);
    check("last_o_valid_drops", last_o_valid === 1'b0);
    repeat (8) tick();

    check("mid_outputs_known", !$isunknown({BCOUT_out, V_result_out, P_fabric_out}));
    check("last_outputs_known", !$isunknown({last_BCOUT_out, last_V_result_out, last_gemm_unit_results}));

    i_clear = 1'b1;
    tick();
    i_clear = 1'b0;
    repeat (4) tick();

    in_H_upper = 4'h1;
    in_H_lower = 4'h1;
    i_weight_valid = 1'b1;
    repeat (4) tick();
    i_weight_valid = 1'b0;
    repeat (3) tick();

    instruction_in_V = 3'b001;
    inst_valid_in_V = 1'b1;
    tick();
    inst_valid_in_V = 1'b0;

    in_V = 8'sd4;
    i_valid = 1'b1;
    mid_arith_nonzero = 1'b0;
    last_arith_nonzero = 1'b0;
    repeat (16) begin
      tick();
      mid_arith_nonzero |= ((V_result_out != '0) || (P_fabric_out != '0));
      last_arith_nonzero |= ((last_V_result_out != '0) || (last_gemm_unit_results != '0));
    end
    i_valid = 1'b0;
    repeat (8) begin
      tick();
      mid_arith_nonzero |= ((V_result_out != '0) || (P_fabric_out != '0));
      last_arith_nonzero |= ((last_V_result_out != '0) || (last_gemm_unit_results != '0));
    end
    $display("DIAG mid inst=%b ce=%b op=%b wU=%0d wL=%0d a=%h b=%h p=%h pc=%h fabric=%h",
             dut_mid.current_inst, dut_mid.dsp_ce_p, dut_mid.dynamic_opmode,
             $signed(dut_mid.w_upper_reg), $signed(dut_mid.w_lower_reg),
             dut_mid.a_packed, dut_mid.b_extended, dut_mid.p_internal,
             V_result_out, P_fabric_out);
    $display("DIAG last inst=%b ce=%b op=%b wU=%0d wL=%0d a=%h b=%h p=%h pc=%h result=%h",
             dut_last.current_inst, dut_last.dsp_ce_p, dut_last.dynamic_opmode,
             $signed(dut_last.w_upper_reg), $signed(dut_last.w_lower_reg),
             dut_last.a_packed, dut_last.b_extended, last_gemm_unit_results,
             last_V_result_out, last_gemm_unit_results);
    check("mid_arithmetic_nonzero", mid_arith_nonzero);
    check("last_arithmetic_nonzero", last_arith_nonzero);

    i_clear = 1'b1;
    tick();
    i_clear = 1'b0;
    repeat (2) tick();
    check("clear_o_valid_mid", o_valid === 1'b0);
    check("clear_o_valid_last", last_o_valid === 1'b0);

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
