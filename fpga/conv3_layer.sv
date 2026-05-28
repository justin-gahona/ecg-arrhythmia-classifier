`timescale 1ns/1ps

module conv3_layer
  import cnn_params_pkg::*;
(
    input  logic       clk,
    input  logic       rst_n,
    // Input: 64 channels for one time position (from conv2)
    input  logic       s_valid,
    output logic       s_ready,
    input  logic signed [7:0] s_data [0:63],
    // Output: 128 channels for one time position
    output logic       m_valid,
    output logic       m_last,
    output logic signed [7:0] m_data [0:127]
);

    localparam int NIF  = 64;
    localparam int NOF  = 128;
    localparam int KS   = 5;
    localparam int NW   = NIF * KS;   // 320 weights per filter
    localparam int OLEN = 348;         // 352 - KS + 1 valid positions

    // Block RAM for weights (40,960 B); distributed ROM for bias (128 B)
    (* ram_style = "block" *)       logic signed [7:0] W [0:CONV3_W_DEPTH-1];
    (* rom_style = "distributed" *) logic signed [7:0] B [0:CONV3_B_DEPTH-1];

    initial begin
        $readmemh("conv3_weight.mem", W);
        $readmemh("conv3_bias.mem",   B);
    end

    // win[tap][channel]: tap 0 = newest frame, tap KS-1 = oldest
    logic signed [7:0] win [0:KS-1][0:NIF-1];

    typedef enum logic [1:0] {ST_FILL, ST_COMPUTE, ST_EMIT} state_t;
    state_t state;

    logic [2:0]  fill_cnt;
    logic [6:0]  filt;       // 0..127
    logic [8:0]  sub;        // 0..NW; sub == NW is the drain cycle
    logic [8:0]  pos;        // 0..347
    logic signed [31:0] acc;

    // Block RAM: 1-cycle synchronous read latency
    logic [15:0]   w_addr;
    logic signed [7:0] w_q;
    always_ff @(posedge clk) w_q <= W[w_addr];

    // Weight index whose data arrives this cycle = sub - 1
    // Layout: W[f * NW + c * KS + t]  =>  wt_idx = c * KS + t
    logic [8:0] wt_idx;
    logic [5:0] c_idx;
    logic [2:0] t_idx;
    logic signed [7:0] win_sel;

    always_comb begin
        wt_idx  = sub - 9'd1;
        c_idx   = wt_idx / KS;
        t_idx   = wt_idx - (c_idx * KS);
        win_sel = win[t_idx][c_idx];
    end

    // Partial accumulator + current BRAM word
    logic signed [31:0] acc_next;
    assign acc_next = acc + ($signed(w_q) * $signed(win_sel));

    // Final result: acc_next (all NW terms) + bias -> shift -> ReLU
    logic signed [31:0] full_acc, full_sh;
    logic signed [7:0]  relu8;

    always_comb begin
        full_acc = acc_next + 32'($signed(B[filt]));
        full_sh  = full_acc >>> CONV3_SHIFT;
        relu8    = (full_sh > 32'sd127) ? 8'sd127 :
                   (full_sh <  32'sd0)  ? 8'sd0   :
                    full_sh[7:0];
    end

    logic signed [7:0] obuf [0:NOF-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_FILL;
            fill_cnt <= '0;
            filt     <= '0;
            sub      <= '0;
            pos      <= '0;
            acc      <= '0;
            w_addr   <= '0;
            s_ready  <= 1'b1;
            m_valid  <= 1'b0;
            m_last   <= 1'b0;
            for (int t = 0; t < KS;  t++)
                for (int c = 0; c < NIF; c++)
                    win[t][c] <= '0;
        end else begin
            m_valid <= 1'b0;

            unique case (state)

                // Accept one 64-channel frame per cycle; shift into window.
                // fill_cnt stays at KS-1 after initial fill so every
                // subsequent position costs exactly 1 fill cycle.
                ST_FILL: begin
                    s_ready <= 1'b1;
                    if (s_valid) begin
                        for (int t = KS-1; t > 0; t--)
                            for (int c = 0; c < NIF; c++)
                                win[t][c] <= win[t-1][c];
                        for (int c = 0; c < NIF; c++)
                            win[0][c] <= s_data[c];
                        if (fill_cnt == 3'(KS-1)) begin
                            state   <= ST_COMPUTE;
                            filt    <= '0;
                            sub     <= '0;
                            acc     <= '0;
                            s_ready <= 1'b0;
                        end else
                            fill_cnt <= fill_cnt + 3'd1;
                    end
                end

                // sub=0:       issue BRAM addr for weight 0, no accumulation
                // sub=1..NW-1: issue next addr, accumulate previous word
                // sub=NW:      drain – last word arrives, apply bias+shift+ReLU
                ST_COMPUTE: begin
                    s_ready <= 1'b0;
                    if (sub < 9'(NW))
                        w_addr <= filt * 9'(NW) + sub;

                    if (sub == 9'(NW)) begin
                        obuf[filt] <= relu8;
                        if (filt == 7'(NOF-1))
                            state <= ST_EMIT;
                        else begin
                            filt <= filt + 7'd1;
                            sub  <= '0;
                            acc  <= '0;
                        end
                    end else begin
                        if (sub >= 9'd1)
                            acc <= acc_next;
                        sub <= sub + 9'd1;
                    end
                end

                ST_EMIT: begin
                    for (int i = 0; i < NOF; i++) m_data[i] <= obuf[i];
                    m_valid <= 1'b1;
                    m_last  <= (pos == 9'(OLEN-1));
                    pos     <= (pos == 9'(OLEN-1)) ? '0 : pos + 9'd1;
                    filt    <= '0;
                    sub     <= '0;
                    acc     <= '0;
                    state   <= ST_FILL;
                    s_ready <= 1'b1;
                end

            endcase
        end
    end

endmodule
