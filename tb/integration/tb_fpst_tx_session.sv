`timescale 1ns/1ps
module tb_fpst_tx_session;
    logic clk=0, rst_n=0, zeroize=0, secure_enable=1;
    logic stage_valid, stage_ready, commit_valid, commit_ready;
    logic activate_valid, activate_ready, tx_commit_valid;
    logic [31:0] sid;
    logic [127:0] key;
    logic [63:0] np, initial_seq, commit_seq;
    logic [31:0] policy;
    logic key_valid, active, err_v;
    logic [31:0] active_sid;
    logic [127:0] active_key;
    logic [63:0] active_np, seq;
    logic [31:0] active_policy;
    logic [15:0] err;
    always #5 clk=~clk;

    fpst_tx_session dut(
        .clk_i(clk),.rst_ni(rst_n),.zeroize_i(zeroize),.secure_enable_i(secure_enable),
        .stage_valid_i(stage_valid),.stage_ready_o(stage_ready),.stage_session_id_i(sid),
        .stage_key_i(key),.stage_nonce_prefix_i(np),.stage_initial_sequence_i(initial_seq),
        .stage_policy_flags_i(policy),.commit_valid_i(commit_valid),.commit_ready_o(commit_ready),
        .commit_session_id_i(sid),.activate_valid_i(activate_valid),.activate_ready_o(activate_ready),
        .activate_session_id_i(sid),.tx_commit_valid_i(tx_commit_valid),
        .tx_commit_sequence_i(commit_seq),.key_valid_o(key_valid),.session_active_o(active),
        .session_id_o(active_sid),.key_o(active_key),.nonce_prefix_o(active_np),
        .sequence_o(seq),.policy_flags_o(active_policy),.error_valid_o(err_v),.error_code_o(err));

    initial begin
        stage_valid=0; commit_valid=0; activate_valid=0; tx_commit_valid=0;
        sid=32'h01020304; key=128'h0f0e0d0c0b0a09080706050403020100;
        np=64'h1716151413121110; initial_seq=0; policy=0; commit_seq=0;
        repeat(3) @(posedge clk); rst_n=1; @(negedge clk);
        if(!stage_ready) $fatal(1,"stage not ready");
        stage_valid=1; @(posedge clk); @(negedge clk); stage_valid=0;
        if(!commit_ready) $fatal(1,"commit not ready");
        commit_valid=1; @(posedge clk); @(negedge clk); commit_valid=0;
        if(!key_valid || active) $fatal(1,"atomic commit state wrong");
        activate_valid=1; @(posedge clk); @(negedge clk); activate_valid=0;
        if(!active) $fatal(1,"session did not activate");
        tx_commit_valid=1; commit_seq=0; @(posedge clk); @(negedge clk); tx_commit_valid=0;
        if(seq!==64'd1) $fatal(1,"sequence did not advance after commit ack");
        zeroize=1; @(posedge clk); @(negedge clk); zeroize=0;
        if(key_valid || active || active_key!=='0 || active_np!=='0) $fatal(1,"zeroize failed");
        $display("PASS: fpst_tx_session atomic commit/activate/zeroize");
        $finish;
    end
endmodule
