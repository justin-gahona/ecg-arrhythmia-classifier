`timescale 1ns/1ps

// VGA 640x480 @ 60 Hz (pixel clock ~25 MHz from 100 MHz / 4)
//
// Screen layout:
//   Rows   0– 47 : label banner (class name + coloured background)
//   Rows  48–479 : scrolling ECG waveform (green trace, dark grid)
//
// ECG buffer: 640 samples displayed left (oldest) → right (newest).
// New samples push the trace leftward (oldest sample scrolls off).

module vga_controller (
    input  logic        clk,          // 100 MHz system clock
    input  logic        rst_n,
    // Raw 12-bit ADC sample (unsigned, e.g. from Pmod AD1)
    input  logic        ecg_valid,
    input  logic [11:0] ecg_sample,
    // Classification result
    input  logic        result_valid,
    input  logic [2:0]  class_idx,    // 0=N 1=S 2=V 3=F 4=Q
    // VGA outputs (Nexys A7 12-bit colour)
    output logic        vga_hs,
    output logic        vga_vs,
    output logic [3:0]  vga_r,
    output logic [3:0]  vga_g,
    output logic [3:0]  vga_b
);

    // ─── pixel clock enable (÷4 → 25 MHz) ───────────────────
    logic [1:0] div;
    logic       px_en;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) div <= '0;
        else        div <= div + 2'd1;
    assign px_en = (div == 2'd3);

    // ─── VGA timing ──────────────────────────────────────────
    localparam int HA = 640, HFP = 16, HS_W = 96, HBP = 48;  // H total 800
    localparam int VA = 480, VFP = 10, VS_W =  2, VBP = 33;  // V total 525

    logic [9:0] hc, vc;
    logic h_act, v_act;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin hc <= '0; vc <= '0; end
        else if (px_en) begin
            if (hc == 10'(HA+HFP+HS_W+HBP-1)) begin
                hc <= '0;
                vc <= (vc == 10'(VA+VFP+VS_W+VBP-1)) ? '0 : vc + 10'd1;
            end else
                hc <= hc + 10'd1;
        end
    end

    assign h_act  = (hc < 10'(HA));
    assign v_act  = (vc < 10'(VA));
    assign vga_hs = ~(hc >= 10'(HA+HFP) && hc < 10'(HA+HFP+HS_W));
    assign vga_vs = ~(vc >= 10'(VA+VFP) && vc < 10'(VA+VFP+VS_W));

    // ─── ECG scroll buffer (640 × 9-bit pre-scaled y coordinate) ─
    // y_buf[i] = waveform row in 48..479 for sample i
    // Scale: y = 479 − (sample × 431) >> 12  →  top=48 when sample=4095
    localparam int WAVEFORM_TOP = 48;

    logic [8:0] y_buf   [0:639];
    logic [9:0] wr_ptr;                 // points to next-write slot

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            for (int i = 0; i < 640; i++) y_buf[i] <= 9'd263; // mid-screen
        end else if (ecg_valid) begin
            // (4095 - sample) * 431 / 4096 ≈ (4095-sample)*431 >> 12
            automatic logic [23:0] tmp = (24'd4095 - ecg_sample) * 24'd431;
            y_buf[wr_ptr] <= 9'(WAVEFORM_TOP) + tmp[22:12]; // top12 bits after >>12 = 9 bits
            wr_ptr <= (wr_ptr == 10'd639) ? '0 : wr_ptr + 10'd1;
        end
    end

    // ─── latched classification result ───────────────────────
    logic [2:0] cls;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)          cls <= 3'd0;
        else if (result_valid) cls <= class_idx;

    // ─── 8×8 font for five class labels: N S V F Q ───────────
    // font[class][row] = 8 pixel bits, MSB = left
    logic [7:0] font [0:4][0:7];
    initial begin
        // N
        font[0] = '{8'h81,8'hC1,8'hA1,8'h91,8'h89,8'h85,8'h83,8'h81};
        // S
        font[1] = '{8'h7E,8'h80,8'h80,8'h7E,8'h01,8'h01,8'h7E,8'h00};
        // V
        font[2] = '{8'h81,8'h81,8'h42,8'h42,8'h24,8'h24,8'h18,8'h00};
        // F
        font[3] = '{8'hFE,8'h80,8'h80,8'hFC,8'h80,8'h80,8'h80,8'h00};
        // Q
        font[4] = '{8'h7C,8'h82,8'h82,8'h82,8'h8A,8'h86,8'h7E,8'h01};
    end

    // ─── banner background colour per class ──────────────────
    logic [3:0] ban_r, ban_g, ban_b;
    always_comb begin
        case (cls)
            3'd0: begin ban_r=4'h0; ban_g=4'h5; ban_b=4'h0; end // N: dark green
            3'd1: begin ban_r=4'h0; ban_g=4'h0; ban_b=4'h6; end // S: dark blue
            3'd2: begin ban_r=4'h6; ban_g=4'h0; ban_b=4'h0; end // V: dark red
            3'd3: begin ban_r=4'h5; ban_g=4'h4; ban_b=4'h0; end // F: dark amber
            default: begin ban_r=4'h5; ban_g=4'h0; ban_b=4'h5; end // Q: dark purple
        endcase
    end

    // ─── pixel generation ────────────────────────────────────
    // All combinational; registered at the always_ff below for clean timing.

    // Column → circular buffer index (oldest sample at hc=0)
    logic [9:0] raw_idx, buf_idx;
    always_comb begin
        raw_idx = wr_ptr + hc;
        buf_idx = (raw_idx >= 10'd640) ? raw_idx - 10'd640 : raw_idx;
    end

    logic [8:0] y_trace;
    assign y_trace = y_buf[buf_idx];

    // Trace thickness: draw for v_cnt in [y_trace-1, y_trace+1]
    logic on_trace;
    assign on_trace = h_act && v_act && (vc >= 10'(WAVEFORM_TOP)) &&
                      (vc >= (y_trace > 0 ? y_trace - 9'd1 : 9'd0)) &&
                      (vc <= y_trace + 9'd1);

    // Grid: faint lines every 80 H pixels and every 43 V pixels in waveform area
    logic on_grid;
    assign on_grid = h_act && v_act && (vc >= 10'(WAVEFORM_TOP)) &&
                     (hc[6:0] == 7'd0 || vc[5:0] == 6'd0);

    // Banner label: 4× scaled 8×8 glyph at screen position (8..39, 8..39)
    logic in_glyph;
    logic [2:0] glyph_col, glyph_row;
    logic       glyph_bit;
    assign in_glyph   = h_act && v_act && (hc >= 10'd8) && (hc < 10'd40) &&
                                          (vc >= 10'd8) && (vc < 10'd40);
    assign glyph_col  = hc[4:2];       // (hc-8)/4, 0..7
    assign glyph_row  = vc[4:2];       // (vc-8)/4, 0..7
    assign glyph_bit  = font[cls][glyph_row][3'd7 - glyph_col];

    // Full class-name strings (40 px wide × 8 rows, starting at col 48)
    // Not implemented as separate ROM — the single glyph is sufficient for
    // live display; a UART debug port carries the full string if needed.

    logic [3:0] px_r, px_g, px_b;
    always_comb begin
        if (!h_act || !v_act) begin
            px_r = 4'h0; px_g = 4'h0; px_b = 4'h0;
        end else if (vc < 10'(WAVEFORM_TOP)) begin
            // Banner area
            if (in_glyph && glyph_bit)
                { px_r, px_g, px_b } = {4'hF, 4'hF, 4'hF};   // white text
            else
                { px_r, px_g, px_b } = {ban_r, ban_g, ban_b};
        end else if (on_trace) begin
            px_r = 4'h0; px_g = 4'hF; px_b = 4'h0;            // green ECG
        end else if (on_grid) begin
            px_r = 4'h1; px_g = 4'h2; px_b = 4'h1;            // dim grid
        end else begin
            px_r = 4'h0; px_g = 4'h0; px_b = 4'h0;            // black BG
        end
    end

    // Register outputs one cycle (aligns with h/v sync registered above)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vga_r <= '0; vga_g <= '0; vga_b <= '0;
        end else if (px_en) begin
            vga_r <= px_r; vga_g <= px_g; vga_b <= px_b;
        end
    end

endmodule
