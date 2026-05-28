`timescale 1ns / 1ps

// 17-tap Hamming-windowed bandpass FIR: 0.5-40 Hz at 360 Hz, Q15 coefficients.
// Input/output: 12-bit unsigned (ADC range 0-4095, DC at 2048).
module fir_filter (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [11:0] sample_in,
    input  logic        sample_valid_in,
    output logic [11:0] sample_out,
    output logic        sample_valid_out
);

    localparam int TAPS = 17;

    localparam signed [15:0] C [0:TAPS-1] = '{
        -16'sd74,   -16'sd179,  -16'sd343,  -16'sd293,
         16'sd433,   16'sd2091,  16'sd4366,  16'sd6382,
         16'sd7192,
         16'sd6382,  16'sd4366,  16'sd2091,   16'sd433,
        -16'sd293,  -16'sd343,  -16'sd179,  -16'sd74
    };

    logic signed [12:0] delay [0:TAPS-1];
    logic signed [33:0] acc;

    // Combinational MAC over current delay line (reads registered state)
    always_comb begin
        acc = '0;
        for (int i = 0; i < TAPS; i++)
            acc = acc + delay[i] * C[i];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < TAPS; i++) delay[i] <= '0;
            sample_out       <= 12'd2048;
            sample_valid_out <= 1'b0;
        end else begin
            sample_valid_out <= 1'b0;
            if (sample_valid_in) begin
                // Shift delay line; strip DC bias from new sample
                for (int i = TAPS-1; i > 0; i--) delay[i] <= delay[i-1];
                delay[0] <= signed'({1'b0, sample_in}) - 13'sd2048;

                // Q15 rescale (>> 15), re-add DC bias, clamp to [0, 4095]
                begin
                    automatic logic signed [18:0] s = acc[33:15];
                    if      (s >  19'sd2047) sample_out <= 12'd4095;
                    else if (s < -19'sd2048) sample_out <= 12'd0;
                    else                     sample_out <= 12'(s + 19'sd2048);
                end

                sample_valid_out <= 1'b1;
            end
        end
    end

endmodule
