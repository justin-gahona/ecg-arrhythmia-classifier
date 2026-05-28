`timescale 1ns/1ps

module conv1_layer
  import cnn_params_pkg::*;
(
    input  logic       clk,
    input  logic       rst_n,
    // Input: one INT8 sample per cycle from beat_buffer
    input  logic       s_valid,
    output logic       s_ready,
    input  logic signed [7:0] s_data,
    // Output: all 32 channel activations for one time position
    output logic       m_valid,
    output logic       m_last,
    output logic signed [7:0] m_data [0:31]
);

    localparam int NF   = 32;           // filters
    localparam int KS   = 5;            // kernel size
    localparam int OLEN = 356;          // 360 - KS + 1 valid positions

    // Distributed LUT ROMs (5 simultaneous reads required by unrolled MAC)
    (* rom_style = "distributed" *) logic signed [7:0] W [0:CONV1_W_DEPTH-1];
    (* rom_style = "distributed" *) logic signed [7:0] B [0:CONV1_B_DEPTH-1];

    initial begin
        $readmemh("conv1_weight.mem", W);
        $readmemh("conv1_bias.mem",   B);
    end

    // 5-sample sliding window
    logic signed [7:0] win [0:KS-1];

    typedef enum logic {ST_FILL, ST_COMPUTE} state_t;
    state_t state;

    logic [2:0] fill_cnt;   // 0..4
    logic [4:0] filt;       // 0..31
    logic [8:0] pos;        // 0..355

    logic signed [7:0] obuf [0:NF-1];

    // Combinational: MAC for current filter, all 5 taps unrolled
    logic signed [31:0] mac, mac_sh;
    logic signed [7:0]  relu8;

    always_comb begin
        mac    = ($signed(W[filt*KS+0]) * $signed(win[0]))
               + ($signed(W[filt*KS+1]) * $signed(win[1]))
               + ($signed(W[filt*KS+2]) * $signed(win[2]))
               + ($signed(W[filt*KS+3]) * $signed(win[3]))
               + ($signed(W[filt*KS+4]) * $signed(win[4]))
               + 32'($signed(B[filt]));
        mac_sh = mac >>> CONV1_SHIFT;
        relu8  = (mac_sh > 32'sd127) ? 8'sd127 :
                 (mac_sh <  32'sd0)  ? 8'sd0   :
                  mac_sh[7:0];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_FILL;
            fill_cnt <= '0;
            filt     <= '0;
            pos      <= '0;
            s_ready  <= 1'b1;
            m_valid  <= 1'b0;
            m_last   <= 1'b0;
            for (int i = 0; i < KS;  i++) win[i]    <= '0;
            for (int i = 0; i < NF;  i++) obuf[i]   <= '0;
            for (int i = 0; i < NF;  i++) m_data[i] <= '0;
        end else begin
            m_valid <= 1'b0;

            unique case (state)
                // Accept one sample per cycle; after 5 samples (then 1 per position)
                // the window is valid and we begin filter evaluation.
                ST_FILL: begin
                    s_ready <= 1'b1;
                    if (s_valid) begin
                        for (int i = KS-1; i > 0; i--) win[i] <= win[i-1];
                        win[0] <= s_data;
                        if (fill_cnt == 3'(KS-1)) begin
                            state   <= ST_COMPUTE;
                            filt    <= '0;
                            s_ready <= 1'b0;
                        end else
                            fill_cnt <= fill_cnt + 3'd1;
                    end
                end

                // One filter per cycle; 32 cycles total.
                // relu8 is computed combinationally from current filt and win.
                ST_COMPUTE: begin
                    s_ready    <= 1'b0;
                    obuf[filt] <= relu8;

                    if (filt == 5'(NF-1)) begin
                        for (int i = 0; i < NF-1; i++) m_data[i] <= obuf[i];
                        m_data[NF-1] <= relu8;  // bypass obuf for last filter
                        m_valid      <= 1'b1;
                        m_last       <= (pos == 9'(OLEN-1));
                        pos          <= (pos == 9'(OLEN-1)) ? '0 : pos + 9'd1;
                        filt         <= '0;
                        state        <= ST_FILL;
                    end else
                        filt <= filt + 5'd1;
                end
            endcase
        end
    end

endmodule
