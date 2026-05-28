`timescale 1ns / 1ps

// Pan-Tompkins R-peak detector (simplified).
// Pipeline: derivative → square → moving-window integration → adaptive threshold.
module rpeak_detector (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [11:0] sample_in,      // from fir_filter, unsigned 12-bit
    input  logic        sample_valid,
    output logic        rpeak           // 1-cycle pulse per detected R-peak
);

    // -------------------------------------------------------------------------
    // Stage 1: Pan-Tompkins derivative  y = 2x[n] + x[n-1] - x[n-3] - 2x[n-4]
    // -------------------------------------------------------------------------
    logic signed [12:0] d [0:4];
    logic signed [14:0] deriv;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 5; i++) d[i] <= '0;
        end else if (sample_valid) begin
            d[0] <= signed'({1'b0, sample_in}) - 13'sd2048;
            for (int i = 1; i < 5; i++) d[i] <= d[i-1];
        end
    end

    assign deriv = (d[0] <<< 1) + d[1] - d[3] - (d[4] <<< 1);

    // -------------------------------------------------------------------------
    // Stage 2: square, scale to 12-bit  (drop lowest 16 bits of 30-bit product)
    // -------------------------------------------------------------------------
    logic [29:0] sq;
    logic [11:0] sq12;

    assign sq   = deriv * deriv;
    assign sq12 = sq[27:16];

    // -------------------------------------------------------------------------
    // Stage 3: 30-sample moving-window integrator (running sum)
    // -------------------------------------------------------------------------
    localparam int MWI_LEN = 30;

    logic [11:0] mwi_buf [0:MWI_LEN-1];
    logic [16:0] mwi_sum;
    logic [11:0] mwi_out;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MWI_LEN; i++) mwi_buf[i] <= '0;
            mwi_sum <= '0;
            mwi_out <= '0;
        end else if (sample_valid) begin
            mwi_sum    <= mwi_sum + sq12 - mwi_buf[MWI_LEN-1];
            mwi_buf[0] <= sq12;
            for (int i = MWI_LEN-1; i > 0; i--) mwi_buf[i] <= mwi_buf[i-1];
            mwi_out    <= mwi_sum[16:5];   // divide by 32 → fits in 12 bits
        end
    end

    // -------------------------------------------------------------------------
    // Stage 4: adaptive threshold + local-max detection + refractory period
    // 200 ms refractory = 72 samples at 360 Hz
    // -------------------------------------------------------------------------
    localparam int REFRACTORY = 72;

    logic [11:0] peak_level;
    logic [11:0] threshold;
    logic [11:0] prev_mwi;
    logic [6:0]  ref_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            peak_level <= 12'd512;
            threshold  <= 12'd256;
            prev_mwi   <= '0;
            ref_cnt    <= '0;
            rpeak      <= 1'b0;
        end else begin
            rpeak <= 1'b0;
            if (ref_cnt != '0) ref_cnt <= ref_cnt - 1;

            if (sample_valid) begin
                // Local maximum: signal was above threshold and is now descending
                if ((prev_mwi >= threshold) && (ref_cnt == '0) && (mwi_out < prev_mwi)) begin
                    rpeak <= 1'b1;
                    if (prev_mwi > peak_level) peak_level <= prev_mwi;
                    threshold <= peak_level >> 1;
                    ref_cnt   <= 7'(REFRACTORY);
                end else if (prev_mwi < threshold) begin
                    // Slowly decay threshold toward noise floor
                    threshold <= threshold - (threshold >> 7);
                end
                prev_mwi <= mwi_out;
            end
        end
    end

endmodule
