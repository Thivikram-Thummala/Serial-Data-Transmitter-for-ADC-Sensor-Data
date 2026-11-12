module piso #(
    parameter WIDTH        = 12,  // ADC bit width (>= 1)
    parameter SYNC_STROBE  = 1    // 1: adc_valid is asynchronous to clk -> 2-FF sync
                                  // 0: adc_valid is already in clk domain
)(
    input  wire             clk,
    input  wire             rst_n,      // active-low async reset
 
    // ADC side
    input  wire [WIDTH-1:0] adc_data,
    input  wire             adc_valid,
 
    // I2C controller side
    input  wire             shift_en,
    output wire             sdo,
    output wire             busy,
    output wire             last_bit,
 
    // status
    output reg              overflow    // 1-clk pulse: a sample was dropped
);
 
    localparam FRAME_W = ((WIDTH + 7) / 8) * 8;
    localparam CNT_W   = $clog2(FRAME_W + 1);
 
    // zero-extend adc_data to FRAME_W (implicit extension on assign; also
    // avoids a zero-width replication when WIDTH is already a multiple of 8)
    wire [FRAME_W-1:0] frame_in = adc_data;
 
    // ---------------- strobe synchronizer + rising-edge detect ----------------
    reg v0, v1, v_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v0  <= 1'b0;
            v1  <= 1'b0;
            v_d <= 1'b0;
        end else begin
            v0  <= adc_valid;
            v1  <= v0;
            v_d <= SYNC_STROBE ? v1 : adc_valid;
        end
    end
 
    wire v_now    = SYNC_STROBE ? v1 : adc_valid;
    wire load_req = v_now & ~v_d;     // one pulse per ADC sample
 
    // ---------------- shift register ----------------
    reg [FRAME_W-1:0] shreg;
    reg [CNT_W-1:0]   cnt;            // bits still to send
    reg               busy_r;
 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shreg    <= {FRAME_W{1'b0}};
            cnt      <= {CNT_W{1'b0}};
            busy_r   <= 1'b0;
            overflow <= 1'b0;
        end else begin
            overflow <= 1'b0;
 
            // advance to the next bit (only possible while busy)
            if (busy_r && shift_en) begin
                shreg <= {shreg[FRAME_W-2:0], 1'b0};
                cnt   <= cnt - 1'b1;
                if (cnt == 1)
                    busy_r <= 1'b0;   // that was the last bit
            end
 
            // new sample: load if idle, otherwise drop it
            // (never collides with a shift, since a shift needs busy_r = 1)
            if (load_req) begin
                if (!busy_r) begin
                    shreg  <= frame_in;
                    cnt    <= FRAME_W[CNT_W-1:0];
                    busy_r <= 1'b1;
                end else begin
                    overflow <= 1'b1;  // sample is dropped
                end
            end
        end
    end
 
    assign busy     = busy_r;
    assign sdo      = busy_r ? shreg[FRAME_W-1] : 1'b0;
    assign last_bit = busy_r && (cnt == 1);
 
endmodule
 
