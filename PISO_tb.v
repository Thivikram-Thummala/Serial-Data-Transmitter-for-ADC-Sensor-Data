`timescale 1ns/1ps
module tb_piso;

    localparam WIDTH   = 12;                       // change to test other widths
    localparam FRAME_W = ((WIDTH + 7) / 8) * 8;

    reg              clk = 0;
    reg              rst_n = 0;
    reg  [WIDTH-1:0] adc_data = 0;
    reg              adc_valid = 0;
    reg              shift_en = 0;
    wire             sdo, busy, last_bit, overflow;

    piso #(.WIDTH(WIDTH), .SYNC_STROBE(1)) dut (
        .clk(clk), .rst_n(rst_n),
        .adc_data(adc_data), .adc_valid(adc_valid),
        .shift_en(shift_en),
        .sdo(sdo), .busy(busy), .last_bit(last_bit),
        .overflow(overflow)
    );

    always #10 clk = ~clk;                         // 50 MHz

    integer errors = 0;
    reg ovf_seen = 0;
    always @(posedge clk) if (overflow) ovf_seen <= 1'b1;

    // ADC strobe: held for 4 clocks, data must stay stable a few clocks after it
    task pulse_valid;
        begin
            @(posedge clk);
            adc_valid <= 1'b1;
            repeat (4) @(posedge clk);
            adc_valid <= 1'b0;
        end
    endtask

    task wait_busy;
        begin
            @(posedge clk);
            while (!busy) @(posedge clk);
        end
    endtask

    // Plays the role of the I2C controller: read bit, then pulse shift_en
    task shift_out(input [FRAME_W-1:0] expected);
        integer i;
        reg [FRAME_W-1:0] got;
        begin
            got = 0;
            for (i = 0; i < FRAME_W; i = i + 1) begin
                @(posedge clk);
                got = {got[FRAME_W-2:0], sdo};
                if (i == FRAME_W-1 && last_bit !== 1'b1) begin
                    errors = errors + 1;
                    $display("FAIL: last_bit not set on final bit");
                end
                if (i != FRAME_W-1 && last_bit !== 1'b0) begin
                    errors = errors + 1;
                    $display("FAIL: last_bit set early at bit %0d", i);
                end
                shift_en <= 1'b1;
                @(posedge clk);
                shift_en <= 1'b0;
            end
            if (got !== expected) begin
                errors = errors + 1;
                $display("FAIL: got %h, expected %h", got, expected);
            end else
                $display("PASS: frame %h", got);
            repeat (2) @(posedge clk);
            if (busy) begin
                errors = errors + 1;
                $display("FAIL: busy still high after frame");
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        // ---- test 1: normal sample ----
        adc_data <= 12'hABC;
        pulse_valid;
        wait_busy;
        shift_out(16'h0ABC);

        // ---- test 2: second sample arrives while busy -> must be dropped ----
        adc_data <= 12'h123;
        pulse_valid;
        wait_busy;
        ovf_seen <= 1'b0;
        adc_data <= 12'hFFF;
        pulse_valid;                               // should be rejected
        repeat (4) @(posedge clk);
        if (!ovf_seen) begin
            errors = errors + 1;
            $display("FAIL: overflow not flagged");
        end
        shift_out(16'h0123);                       // original sample must survive

        // ---- test 3: back-to-back normal sample after idle ----
        adc_data <= 12'h555;
        pulse_valid;
        wait_busy;
        shift_out(16'h0555);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d ERROR(S)", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule