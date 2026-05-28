`timescale 1ns/1ps

// Top-level for Nexys A7-100T ECG arrhythmia classifier.
//
// Signal chain:
//   Pmod AD1 → spi_master → fir_filter → beat_buffer
//                                       → rpeak_detector ┘
//   beat_buffer → [beat adapter] → cnn_inference → result
//   fir_filter  → vga_controller  (live waveform)
//   result      → vga_controller  (class label)
//   result      → LEDs            (one-hot class)

module top (
    input  logic        clk,           // 100 MHz oscillator (E3)
    input  logic        cpu_resetn,    // Active-low reset pushbutton (C12)

    // Pmod AD1 (AD7476A SPI ADC) on Pmod JA
    input  logic        ad1_miso,      // JA1 = C17
    output logic        ad1_sck,       // JA3 = E18
    output logic        ad1_csn,       // JA4 = G17

    // VGA
    output logic        vga_hs,
    output logic        vga_vs,
    output logic [3:0]  vga_r,
    output logic [3:0]  vga_g,
    output logic [3:0]  vga_b,

    // LEDs: one-hot class (LD4:LD0) + beat indicator (LD7)
    output logic [7:0]  led
);

    // ─── reset synchroniser (active-low button → synchronous rst_n) ──────
    logic [1:0] rst_sync;
    logic       rst_n;
    always_ff @(posedge clk or negedge cpu_resetn) begin
        if (!cpu_resetn) rst_sync <= 2'b00;
        else             rst_sync <= {rst_sync[0], 1'b1};
    end
    assign rst_n = rst_sync[1];

    // ─── ADC + signal chain ───────────────────────────────────────────────
    logic [11:0] spi_sample;
    logic        spi_valid;

    spi_master u_spi (
        .clk          (clk),
        .rst_n        (rst_n),
        .cs_n         (ad1_csn),
        .sck          (ad1_sck),
        .miso         (ad1_miso),
        .sample       (spi_sample),
        .sample_valid (spi_valid)
    );

    logic [11:0] fir_out;
    logic        fir_valid;

    fir_filter u_fir (
        .clk              (clk),
        .rst_n            (rst_n),
        .sample_in        (spi_sample),
        .sample_valid_in  (spi_valid),
        .sample_out       (fir_out),
        .sample_valid_out (fir_valid)
    );

    logic rpeak;

    rpeak_detector u_rpeak (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_in    (fir_out),
        .sample_valid (fir_valid),
        .rpeak        (rpeak)
    );

    logic        beat_ready;
    logic [8:0]  bb_rd_addr;
    logic [11:0] bb_rd_data;

    beat_buffer u_beat (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_in    (fir_out),
        .sample_valid (fir_valid),
        .rpeak        (rpeak),
        .beat_ready   (beat_ready),
        .rd_addr      (bb_rd_addr),
        .rd_data      (bb_rd_data)
    );

    // ─── beat → cnn_inference adapter ────────────────────────────────────
    // When beat_ready pulses, walk rd_addr 0..359, convert each 12-bit
    // sample to signed INT8 (top 8 bits, MSB-flipped) and stream into the CNN.
    // Backpressure: advance only when cnn_s_ready=1.

    typedef enum logic {AD_IDLE, AD_STREAM} ad_state_t;
    ad_state_t   ad_state;
    logic [8:0]  ad_addr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ad_state <= AD_IDLE;
            ad_addr  <= '0;
        end else begin
            unique case (ad_state)
                AD_IDLE: begin
                    if (beat_ready) begin
                        ad_addr  <= '0;
                        ad_state <= AD_STREAM;
                    end
                end
                AD_STREAM: begin
                    if (cnn_s_ready) begin
                        if (ad_addr == 9'd359) ad_state <= AD_IDLE;
                        else                   ad_addr  <= ad_addr + 9'd1;
                    end
                end
            endcase
        end
    end

    logic        cnn_s_valid, cnn_s_ready;
    logic signed [7:0] cnn_s_data;

    // rd_data is combinational from beat_buffer; stable between rising edges.
    // Flip the MSB of the top 8 bits to convert unsigned 0-255 → signed -128..127.
    assign bb_rd_addr = ad_addr;
    assign cnn_s_valid = (ad_state == AD_STREAM);
    assign cnn_s_data  = $signed(bb_rd_data[11:4] ^ 8'h80);

    // ─── CNN inference ────────────────────────────────────────────────────
    logic        result_valid;
    logic [2:0]  class_idx;

    cnn_inference u_cnn (
        .clk          (clk),
        .rst_n        (rst_n),
        .s_valid      (cnn_s_valid),
        .s_ready      (cnn_s_ready),
        .s_data       (cnn_s_data),
        .result_valid (result_valid),
        .class_idx    (class_idx)
    );

    // ─── VGA controller ───────────────────────────────────────────────────
    // Feed the live filtered waveform for continuous ECG display.
    vga_controller u_vga (
        .clk          (clk),
        .rst_n        (rst_n),
        .ecg_valid    (fir_valid),
        .ecg_sample   (fir_out),
        .result_valid (result_valid),
        .class_idx    (class_idx),
        .vga_hs       (vga_hs),
        .vga_vs       (vga_vs),
        .vga_r        (vga_r),
        .vga_g        (vga_g),
        .vga_b        (vga_b)
    );

    // ─── LED indicators ───────────────────────────────────────────────────
    // LD4:LD0 = one-hot class, LD7 = beat indicator (flashes on each beat)
    logic beat_led;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        beat_led <= 1'b0;
        else if (rpeak)    beat_led <= ~beat_led;
    end

    logic [4:0] class_onehot;
    always_comb begin
        class_onehot = 5'b00000;
        if (result_valid || class_idx != 3'd0)   // keep last result
            class_onehot[class_idx[2:0]] = 1'b1;
    end

    // Latch class_onehot until next result
    logic [4:0] class_latch;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          class_latch <= '0;
        else if (result_valid) class_latch <= class_onehot;
    end

    assign led = {beat_led, 2'b00, class_latch};

endmodule
