`timescale 1ns/1ps

module pool_layer (
    input  logic        clk,
    input  logic        rst_n,
    // Input: 128-channel frame from conv3, one per s_valid
    input  logic        s_valid,
    output logic        s_ready,
    input  logic signed [7:0] s_data [0:127],
    // Output: 512 INT8 values streamed one per cycle to fc1_layer
    output logic        m_valid,
    input  logic        m_ready,
    output logic signed [7:0] m_data
);

    localparam int NCH      = 128;
    localparam int ILEN     = 348;
    localparam int OLEN     = 4;
    localparam int BIN_SIZE = 87;   // ILEN / OLEN, exact

    // 128 x 4 INT32 accumulators; sum[c][b] in [0, 87*127=11049] after ReLU
    logic signed [31:0] sum [0:NCH-1][0:OLEN-1];

    typedef enum logic {ST_ACCUM, ST_OUT} state_t;
    state_t state;

    logic [1:0] bin_cnt;    // current accumulation bin: 0..3
    logic [6:0] bin_pos;    // position within bin: 0..86
    logic [6:0] out_c;      // output channel: 0..127
    logic [1:0] out_bin;    // output bin: 0..3

    // Combinational average: 3013/2^18 ≈ 1/87.004 (error < 0.01%)
    logic signed [31:0] avg32;
    always_comb begin
        avg32  = (sum[out_c][out_bin] * 32'sd3013) >>> 18;
        m_data = (avg32 > 32'sd127) ? 8'sd127 :
                 (avg32 <  32'sd0)  ? 8'sd0   :
                  avg32[7:0];
    end

    // m_valid and s_ready are purely state-driven
    assign m_valid = (state == ST_OUT);
    assign s_ready = (state == ST_ACCUM);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= ST_ACCUM;
            bin_cnt <= '0;
            bin_pos <= '0;
            out_c   <= '0;
            out_bin <= '0;
            for (int c = 0; c < NCH;  c++)
                for (int b = 0; b < OLEN; b++)
                    sum[c][b] <= '0;
        end else begin

            case (state)

                // Receive 348 frames: accumulate all 128 channels per cycle.
                // bin = bin_cnt advances every BIN_SIZE=87 frames.
                ST_ACCUM: begin
                    if (s_valid) begin
                        for (int c = 0; c < NCH; c++)
                            sum[c][bin_cnt] <= sum[c][bin_cnt] + 32'($signed(s_data[c]));

                        if (bin_pos == 7'(BIN_SIZE-1)) begin
                            bin_pos <= '0;
                            if (bin_cnt == 2'(OLEN-1)) begin
                                // All 348 samples accumulated; stream averages
                                state   <= ST_OUT;
                                out_c   <= '0;
                                out_bin <= '0;
                                bin_cnt <= '0;
                            end else
                                bin_cnt <= bin_cnt + 2'd1;
                        end else
                            bin_pos <= bin_pos + 7'd1;
                    end
                end

                // Stream 512 averages in channel-outer, bin-inner order:
                // [ch0_bin0, ch0_bin1, ch0_bin2, ch0_bin3, ch1_bin0, ...]
                // m_data is computed combinationally from sum[out_c][out_bin].
                // Advance on m_ready (fc1_layer s_ready).
                ST_OUT: begin
                    if (m_ready) begin
                        if (out_c == 7'(NCH-1) && out_bin == 2'(OLEN-1)) begin
                            for (int c = 0; c < NCH; c++)
                                for (int b = 0; b < OLEN; b++)
                                    sum[c][b] <= '0;
                            state <= ST_ACCUM;
                        end else if (out_bin == 2'(OLEN-1)) begin
                            out_c   <= out_c + 7'd1;
                            out_bin <= '0;
                        end else
                            out_bin <= out_bin + 2'd1;
                    end
                end

            endcase
        end
    end

endmodule
