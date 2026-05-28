`timescale 1ns/1ps

module fc1_layer
  import cnn_params_pkg::*;
(
    input  logic       clk,
    input  logic       rst_n,
    // Input: 512 INT8 values streamed one per cycle
    input  logic       s_valid,
    output logic       s_ready,
    input  logic signed [7:0] s_data,
    // Output: 128 INT8 values (single vector, ReLU applied)
    output logic       m_valid,
    output logic signed [7:0] m_data [0:127]
);

    localparam int NIN  = 512;
    localparam int NOUT = 128;

    // Input buffer: Vivado infers LUTRAM with async read (written in always_ff,
    // read combinationally via variable index below)
    logic signed [7:0] in_buf [0:NIN-1];

    // Block RAM for weights (65,536 B); distributed ROM for bias (128 B)
    (* ram_style = "block" *)       logic signed [7:0] W [0:FC1_W_DEPTH-1];
    (* rom_style = "distributed" *) logic signed [7:0] B [0:FC1_B_DEPTH-1];

    initial begin
        $readmemh("fc1_weight.mem", W);
        $readmemh("fc1_bias.mem",   B);
    end

    typedef enum logic [1:0] {ST_LOAD, ST_COMPUTE, ST_EMIT} state_t;
    state_t state;

    logic [8:0]  load_cnt;   // 0..511
    logic [6:0]  neuron;     // 0..127
    logic [9:0]  sub;        // 0..NIN; sub == NIN is the drain cycle
    logic signed [31:0] acc;

    // Block RAM: 1-cycle synchronous read latency
    logic [15:0]   w_addr;
    logic signed [7:0] w_q;
    always_ff @(posedge clk) w_q <= W[w_addr];

    // Combinational: input element paired with BRAM data arriving this cycle.
    // Data from address (neuron*NIN + sub-1) arrives when sub >= 1.
    // sub[8:0] - 1 wraps correctly at sub=512 (9'd0 - 1 = 9'd511).
    logic [8:0]  wt_idx;
    logic signed [7:0] in_q;
    always_comb begin
        wt_idx = sub[8:0] - 9'd1;
        in_q   = in_buf[wt_idx];
    end

    // Partial accumulator + current BRAM word
    logic signed [31:0] acc_next;
    assign acc_next = acc + ($signed(w_q) * $signed(in_q));

    // Final result: acc_next (all NIN terms) + bias -> shift -> ReLU
    logic signed [31:0] full_acc, full_sh;
    logic signed [7:0]  relu8;
    always_comb begin
        full_acc = acc_next + 32'($signed(B[neuron]));
        full_sh  = full_acc >>> FC1_SHIFT;
        relu8    = (full_sh > 32'sd127) ? 8'sd127 :
                   (full_sh <  32'sd0)  ? 8'sd0   :
                    full_sh[7:0];
    end

    logic signed [7:0] obuf [0:NOUT-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_LOAD;
            load_cnt <= '0;
            neuron   <= '0;
            sub      <= '0;
            acc      <= '0;
            w_addr   <= '0;
            s_ready  <= 1'b1;
            m_valid  <= 1'b0;
        end else begin
            m_valid <= 1'b0;

            unique case (state)

                // Stream in NIN=512 INT8 values, one per cycle
                ST_LOAD: begin
                    s_ready <= 1'b1;
                    if (s_valid) begin
                        in_buf[load_cnt] <= s_data;
                        if (load_cnt == 9'(NIN-1)) begin
                            state    <= ST_COMPUTE;
                            load_cnt <= '0;
                            neuron   <= '0;
                            sub      <= '0;
                            acc      <= '0;
                            s_ready  <= 1'b0;
                        end else
                            load_cnt <= load_cnt + 9'd1;
                    end
                end

                // sub=0:        issue BRAM addr for weight 0, no accumulation
                // sub=1..NIN-1: issue next addr, accumulate previous BRAM word
                // sub=NIN:      drain – last word arrives, apply bias+shift+ReLU
                // Wrapping of sub[8:0] at sub=NIN=512 pairs the drain cycle with
                // in_buf[511], which is the correct last input element.
                ST_COMPUTE: begin
                    s_ready <= 1'b0;
                    if (sub < 10'(NIN))
                        w_addr <= neuron * NIN + sub[8:0];

                    if (sub == 10'(NIN)) begin
                        obuf[neuron] <= relu8;
                        if (neuron == 7'(NOUT-1))
                            state <= ST_EMIT;
                        else begin
                            neuron <= neuron + 7'd1;
                            sub    <= '0;
                            acc    <= '0;
                        end
                    end else begin
                        if (sub >= 10'd1)
                            acc <= acc_next;
                        sub <= sub + 10'd1;
                    end
                end

                ST_EMIT: begin
                    for (int i = 0; i < NOUT; i++) m_data[i] <= obuf[i];
                    m_valid  <= 1'b1;
                    neuron   <= '0;
                    sub      <= '0;
                    acc      <= '0;
                    state    <= ST_LOAD;
                    s_ready  <= 1'b1;
                end

            endcase
        end
    end

endmodule
