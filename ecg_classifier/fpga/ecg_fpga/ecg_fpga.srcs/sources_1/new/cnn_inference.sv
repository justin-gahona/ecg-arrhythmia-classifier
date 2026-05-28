`timescale 1ns/1ps

module cnn_inference
  import cnn_params_pkg::*;
(
    input  logic       clk,
    input  logic       rst_n,
    // From beat_buffer: 360 INT8 samples, one per s_valid
    input  logic       s_valid,
    output logic       s_ready,
    input  logic signed [7:0] s_data,
    // Classification result
    output logic       result_valid,
    output logic [2:0] class_idx
);

    // ──────────────────────────────────────────────────────────
    //  Inter-layer wires
    // ──────────────────────────────────────────────────────────

    // conv1 → conv2
    logic        c1_valid, c1_last;
    logic signed [7:0] c1_data [0:31];

    // conv2 → conv3
    logic        c2_valid, c2_last;
    logic signed [7:0] c2_data [0:63];

    // conv3 → pool
    logic        c3_valid, c3_last;
    logic signed [7:0] c3_data [0:127];

    // pool → fc1  (pool streams one byte at a time; fc1 s_ready gates it)
    logic        p_valid,  p_ready;
    logic signed [7:0] p_data;

    // fc1 → fc2  (fc1 emits 128-wide array in one cycle)
    logic        f1_valid;
    logic signed [7:0] f1_data [0:127];

    // fc2 → argmax  (fc2 emits 5-wide array in one cycle)
    logic        f2_valid;
    logic signed [7:0] f2_data [0:4];

    // ──────────────────────────────────────────────────────────
    //  Layer instantiations
    // ──────────────────────────────────────────────────────────

    conv1_layer u_conv1 (
        .clk     (clk),      .rst_n   (rst_n),
        .s_valid (s_valid),  .s_ready (s_ready),  .s_data (s_data),
        .m_valid (c1_valid), .m_last  (c1_last),  .m_data (c1_data)
    );

    // conv2 s_ready is driven but not consumed by conv1 — the pipeline relies
    // on beat_buffer pacing samples to the end-to-end throughput (one beat per
    // ~180 ms at 100 MHz, well within a 600 ms inter-beat interval at 100 bpm).
    logic c2_ready, c3_ready;

    conv2_layer u_conv2 (
        .clk     (clk),      .rst_n   (rst_n),
        .s_valid (c1_valid), .s_ready (c2_ready), .s_data (c1_data),
        .m_valid (c2_valid), .m_last  (c2_last),  .m_data (c2_data)
    );

    conv3_layer u_conv3 (
        .clk     (clk),      .rst_n   (rst_n),
        .s_valid (c2_valid), .s_ready (c3_ready), .s_data (c2_data),
        .m_valid (c3_valid), .m_last  (c3_last),  .m_data (c3_data)
    );

    pool_layer u_pool (
        .clk     (clk),      .rst_n   (rst_n),
        .s_valid (c3_valid), .s_ready (/* unused */), .s_data (c3_data),
        .m_valid (p_valid),  .m_ready (p_ready),      .m_data (p_data)
    );

    fc1_layer u_fc1 (
        .clk     (clk),     .rst_n   (rst_n),
        .s_valid (p_valid), .s_ready (p_ready), .s_data (p_data),
        .m_valid (f1_valid),                    .m_data (f1_data)
    );

    // fc2 s_ready unused: fc2 is always in ST_LOAD when fc1 emits its one-shot
    // m_valid (there is exactly one fc1 output per inference).
    logic f2_ready_nc;

    fc2_layer u_fc2 (
        .clk     (clk),      .rst_n   (rst_n),
        .s_valid (f1_valid), .s_ready (f2_ready_nc), .s_data (f1_data),
        .m_valid (f2_valid),                          .m_data (f2_data)
    );

    // ──────────────────────────────────────────────────────────
    //  Argmax over 5 signed logits (priority-encoded, registered)
    //  Classes: 0=N 1=S 2=V 3=F 4=Q  (MIT-BIH AAMI mapping)
    // ──────────────────────────────────────────────────────────

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_valid <= 1'b0;
            class_idx    <= 3'd0;
        end else begin
            result_valid <= 1'b0;
            if (f2_valid) begin
                result_valid <= 1'b1;
                if      ($signed(f2_data[0]) >= $signed(f2_data[1]) &&
                         $signed(f2_data[0]) >= $signed(f2_data[2]) &&
                         $signed(f2_data[0]) >= $signed(f2_data[3]) &&
                         $signed(f2_data[0]) >= $signed(f2_data[4])) class_idx <= 3'd0;
                else if ($signed(f2_data[1]) >= $signed(f2_data[2]) &&
                         $signed(f2_data[1]) >= $signed(f2_data[3]) &&
                         $signed(f2_data[1]) >= $signed(f2_data[4])) class_idx <= 3'd1;
                else if ($signed(f2_data[2]) >= $signed(f2_data[3]) &&
                         $signed(f2_data[2]) >= $signed(f2_data[4])) class_idx <= 3'd2;
                else if ($signed(f2_data[3]) >= $signed(f2_data[4])) class_idx <= 3'd3;
                else                                                   class_idx <= 3'd4;
            end
        end
    end

endmodule
