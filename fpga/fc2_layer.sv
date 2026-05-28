`timescale 1ns/1ps

module fc2_layer
  import cnn_params_pkg::*;
(
    input  logic       clk,
    input  logic       rst_n,
    // Input: 128 INT8 values loaded in one cycle (directly from fc1 m_data)
    input  logic       s_valid,
    output logic       s_ready,
    input  logic signed [7:0] s_data [0:127],
    // Output: 5 raw INT8 logits (no ReLU; argmax is performed externally)
    output logic       m_valid,
    output logic signed [7:0] m_data [0:4]
);

    localparam int NIN  = 128;
    localparam int NOUT = 5;

    // Input buffer: 128 registers, loaded all-at-once in ST_LOAD
    logic signed [7:0] in_buf [0:NIN-1];

    // Distributed ROM for weights (640 B) and bias (5 B).
    // All NOUT weight reads per cycle are independent combinational lookups.
    (* rom_style = "distributed" *) logic signed [7:0] W [0:FC2_W_DEPTH-1];
    (* rom_style = "distributed" *) logic signed [7:0] B [0:FC2_B_DEPTH-1];

    initial begin
        $readmemh("fc2_weight.mem", W);
        $readmemh("fc2_bias.mem",   B);
    end

    typedef enum logic [1:0] {ST_LOAD, ST_COMPUTE, ST_EMIT} state_t;
    state_t state;

    logic [6:0]  cnt;                        // 0..127
    logic signed [31:0] acc [0:NOUT-1];      // 5 parallel accumulators

    // Combinational final computation (bias + shift), active during ST_EMIT
    logic signed [31:0] fin [0:NOUT-1];
    logic signed [31:0] fins[0:NOUT-1];

    always_comb begin
        for (int o = 0; o < NOUT; o++) begin
            fin[o]  = acc[o] + 32'($signed(B[o]));
            fins[o] = fin[o] >>> FC2_SHIFT;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= ST_LOAD;
            cnt     <= '0;
            s_ready <= 1'b1;
            m_valid <= 1'b0;
            for (int o = 0; o < NOUT; o++) acc[o] <= '0;
        end else begin
            m_valid <= 1'b0;

            unique case (state)

                // Accept all NIN=128 inputs in a single cycle
                ST_LOAD: begin
                    s_ready <= 1'b1;
                    if (s_valid) begin
                        for (int c = 0; c < NIN; c++) in_buf[c] <= s_data[c];
                        for (int o = 0; o < NOUT; o++) acc[o]   <= '0;
                        cnt     <= '0;
                        state   <= ST_COMPUTE;
                        s_ready <= 1'b0;
                    end
                end

                // 128 cycles: 5 parallel MAC operations per cycle.
                // Distributed ROM has no read latency so accumulation
                // is direct with no pipeline drain cycle.
                // Layout: W[o * NIN + cnt]  =>  W[o*128 + cnt]
                ST_COMPUTE: begin
                    s_ready <= 1'b0;
                    for (int o = 0; o < NOUT; o++)
                        acc[o] <= acc[o] + ($signed(W[o * NIN + cnt]) * $signed(in_buf[cnt]));

                    if (cnt == 7'(NIN-1))
                        state <= ST_EMIT;
                    else
                        cnt <= cnt + 7'd1;
                end

                // acc[] now holds the full dot product from cnt=0..127.
                // Apply bias, right-shift, and clamp to signed INT8 range.
                // No ReLU: negative logits are meaningful for argmax.
                ST_EMIT: begin
                    for (int o = 0; o < NOUT; o++)
                        m_data[o] <= (fins[o] > 32'sd127)   ?  8'sd127  :
                                     (fins[o] < -32'sd128)  ? -8'sd128  :
                                      fins[o][7:0];
                    m_valid <= 1'b1;
                    cnt     <= '0;
                    state   <= ST_LOAD;
                    s_ready <= 1'b1;
                end

            endcase
        end
    end

endmodule
