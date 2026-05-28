`timescale 1ns / 1ps

// Captures a 360-sample beat window centered on each R-peak.
// Keeps a 512-sample circular buffer. On rpeak pulse, waits 180 more
// samples then exposes the full window via rd_addr/rd_data to the CNN.
// R-peak lands at rd_addr = 180, matching MIT-BIH beat segmentation.
module beat_buffer (
    input  logic        clk,
    input  logic        rst_n,
    // From fir_filter
    input  logic [11:0] sample_in,
    input  logic        sample_valid,
    // From rpeak_detector
    input  logic        rpeak,
    // To CNN — random-access read port
    output logic        beat_ready,    // 1-cycle pulse per captured beat
    input  logic [8:0]  rd_addr,       // 0..359
    output logic [11:0] rd_data
);

    localparam int CIRC = 512;
    localparam int BEAT = 360;
    localparam int HALF = 180;

    logic [11:0] circ [0:CIRC-1];
    logic [8:0]  head;
    logic [8:0]  start_addr;
    logic [7:0]  post_cnt;
    logic        capturing;

    // Combinational read; 9-bit addition wraps naturally at 512
    assign rd_data = circ[(start_addr + rd_addr) & 9'(CIRC-1)];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head       <= '0;
            start_addr <= '0;
            post_cnt   <= '0;
            capturing  <= 1'b0;
            beat_ready <= 1'b0;
        end else begin
            beat_ready <= 1'b0;

            if (sample_valid) begin
                circ[head] <= sample_in;
                head       <= 9'((head + 1) & (CIRC-1));

                if (rpeak && !capturing) begin
                    capturing <= 1'b1;
                    post_cnt  <= 8'd0;
                end else if (capturing) begin
                    if (post_cnt == 8'(HALF - 1)) begin
                        // head (old) = rpeak_head + HALF
                        // start = rpeak_head - HALF = head - BEAT
                        start_addr <= 9'((head - BEAT) & (CIRC-1));
                        capturing  <= 1'b0;
                        beat_ready <= 1'b1;
                    end else
                        post_cnt <= post_cnt + 1;
                end
            end
        end
    end

endmodule
