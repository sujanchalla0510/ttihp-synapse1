/*
 * Synapse-1: Hybrid Neuromorphic Controller
 * TinyTapeout Wrapper for 8x8 Knowm Memristor Crossbar Interface
 *
 * Copyright (c) 2024-2026 Sujan Challa
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_sujanreddy_synapse (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // Always 1 when design is powered
    input  wire       clk,      // Clock
    input  wire       rst_n     // Reset (active low)
);

    // =========================================================================
    // Pin Mapping
    // =========================================================================
    //
    // Dedicated Inputs (ui_in[7:0]):
    //   ui_in[0] = SPI Chip Select (active low)
    //   ui_in[1] = SPI Clock
    //   ui_in[2] = SPI MOSI (Master Out, Slave In)
    //   ui_in[3] = Programming Enable (safety interlock)
    //   ui_in[7:4] = Column Sense [3:0] (from TIA/comparator)
    //
    // Dedicated Outputs (uo_out[7:0]):
    //   uo_out[0] = SPI MISO (Master In, Slave Out)
    //   uo_out[1] = Ready status
    //   uo_out[2] = Error status
    //   uo_out[3] = Programming Done status
    //   uo_out[7:4] = Unused
    //
    // Bidirectional IOs (uio[7:0]) - configured as OUTPUTS:
    //   uio_out[7:0] = Row Drive [7:0] (to memristor rows via interface PCB)
    //
    // =========================================================================

    // Internal signals
    wire        spi_cs_n   = ui_in[0];
    wire        spi_sck    = ui_in[1];
    wire        spi_mosi   = ui_in[2];
    wire        prog_en    = ui_in[3];
    wire [7:0]  col_sense  = {4'b0000, ui_in[7:4]};  // Upper 4 bits not connected

    wire        spi_miso;
    wire [7:0]  row_drive;
    wire        row_drive_oe;
    wire        ready;
    wire        error;
    wire        prog_done;

    // =========================================================================
    // Controller Instance
    // =========================================================================
    Controller controller_inst (
        .clk          (clk),
        .rst_n        (rst_n),
        .spi_cs_n     (spi_cs_n),
        .spi_sck      (spi_sck),
        .spi_mosi     (spi_mosi),
        .spi_miso     (spi_miso),
        .prog_en      (prog_en),
        .row_drive    (row_drive),
        .row_drive_oe (row_drive_oe),
        .col_sense    (col_sense),
        .ready        (ready),
        .error        (error),
        .prog_done    (prog_done)
    );

    // =========================================================================
    // Output Assignments
    // =========================================================================
    assign uo_out[0] = spi_miso;
    assign uo_out[1] = ready;
    assign uo_out[2] = error;
    assign uo_out[3] = prog_done;
    assign uo_out[7:4] = 4'b0000;

    assign uio_out = row_drive;
    assign uio_oe  = {8{row_drive_oe}};

    // Unused inputs
    wire _unused = &{ena, uio_in, 1'b0};

endmodule


// =============================================================================
// Controller Module
// Digital controller for external 8x8 Knowm memristor crossbar
// =============================================================================

module Controller (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        spi_cs_n,
    input  wire        spi_sck,
    input  wire        spi_mosi,
    output reg         spi_miso,
    input  wire        prog_en,
    output reg  [7:0]  row_drive,
    output reg         row_drive_oe,
    input  wire [7:0]  col_sense,
    output wire        ready,
    output wire        error,
    output wire        prog_done
);

    // Command Definitions
    localparam CMD_NOP         = 8'h00;
    localparam CMD_SET_ROW     = 8'h01;
    localparam CMD_READ_COL    = 8'h02;
    localparam CMD_PROG_CELL   = 8'h03;
    localparam CMD_READ_STATUS = 8'h04;
    localparam CMD_FORM        = 8'h05;
    localparam CMD_SET_TIMING  = 8'h06;
    localparam CMD_READ_CELL   = 8'h07;

    // State Machine
    localparam STATE_IDLE       = 4'd0;
    localparam STATE_CMD        = 4'd1;
    localparam STATE_DATA1      = 4'd2;
    localparam STATE_DATA2      = 4'd3;
    localparam STATE_EXECUTE    = 4'd4;
    localparam STATE_PROG_PULSE = 4'd5;
    localparam STATE_PROG_WAIT  = 4'd6;
    localparam STATE_READ_WAIT  = 4'd7;
    localparam STATE_RESPOND    = 4'd8;
    localparam STATE_FORM       = 4'd9;

    reg [3:0] state;

    // SPI Registers
    reg [7:0] shift_reg_in;
    reg [7:0] shift_reg_out;
    reg [2:0] bit_cnt;
    reg       byte_ready;

    // SCK/CS edge detection
    reg sck_d1, sck_d2, sck_d3;
    wire sck_rising  = sck_d2 && !sck_d3;
    wire sck_falling = !sck_d2 && sck_d3;

    reg cs_d1, cs_d2;
    wire cs_falling = !cs_d1 && cs_d2;

    // Command/Data Registers
    reg [7:0] cmd_reg;
    reg [7:0] data_reg1;
    reg [7:0] data_reg2;

    // Programming Timing
    reg [15:0] pulse_width;
    reg [15:0] pulse_counter;
    reg [15:0] form_width;

    // Status Registers
    reg        status_ready;
    reg        status_error;
    reg        status_prog_done;
    reg [7:0]  last_col_read;

    assign ready     = status_ready;
    assign error     = status_error;
    assign prog_done = status_prog_done;

    // Synchronizers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck_d1 <= 1'b0;
            sck_d2 <= 1'b0;
            sck_d3 <= 1'b0;
            cs_d1  <= 1'b1;
            cs_d2  <= 1'b1;
        end else begin
            sck_d1 <= spi_sck;
            sck_d2 <= sck_d1;
            sck_d3 <= sck_d2;
            cs_d1  <= spi_cs_n;
            cs_d2  <= cs_d1;
        end
    end

    // SPI Shift Logic (Mode 0: CPOL=0, CPHA=0)
    // Note: shift_reg_out is controlled by main FSM only
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg_in  <= 8'h00;
            bit_cnt       <= 3'd0;
            byte_ready    <= 1'b0;
            spi_miso      <= 1'b0;
        end else begin
            byte_ready <= 1'b0;

            if (cs_d2) begin
                bit_cnt <= 3'd0;
                spi_miso <= shift_reg_out[7];
            end else begin
                if (sck_rising) begin
                    shift_reg_in <= {shift_reg_in[6:0], spi_mosi};
                    bit_cnt <= bit_cnt + 1'b1;
                    if (bit_cnt == 3'd7) begin
                        byte_ready <= 1'b1;
                    end
                end

                if (sck_falling) begin
                    if (bit_cnt == 3'd0) begin
                        spi_miso <= shift_reg_out[7];
                    end else begin
                        spi_miso <= shift_reg_out[7 - bit_cnt];
                    end
                end
            end
        end
    end

    // Main State Machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= STATE_IDLE;
            cmd_reg          <= 8'h00;
            data_reg1        <= 8'h00;
            data_reg2        <= 8'h00;
            row_drive        <= 8'h00;
            row_drive_oe     <= 1'b1;
            status_ready     <= 1'b1;
            status_error     <= 1'b0;
            status_prog_done <= 1'b0;
            pulse_width      <= 16'd1000;
            form_width       <= 16'd5000;
            pulse_counter    <= 16'd0;
            last_col_read    <= 8'h00;
            shift_reg_out    <= 8'h00;
        end else begin
            case (state)

                STATE_IDLE: begin
                    status_ready <= 1'b1;
                    if (!cs_d2 && byte_ready) begin
                        cmd_reg <= shift_reg_in;
                        state <= STATE_CMD;
                    end
                end

                STATE_CMD: begin
                    status_ready <= 1'b0;
                    case (cmd_reg)
                        CMD_NOP: begin
                            state <= STATE_IDLE;
                            status_ready <= 1'b1;
                        end

                        CMD_SET_ROW: begin
                            if (byte_ready) begin
                                data_reg1 <= shift_reg_in;
                                state <= STATE_EXECUTE;
                            end
                        end

                        CMD_READ_COL: begin
                            last_col_read <= col_sense;
                            shift_reg_out <= col_sense;
                            state <= STATE_RESPOND;
                        end

                        CMD_PROG_CELL: begin
                            if (!prog_en) begin
                                status_error <= 1'b1;
                                state <= STATE_IDLE;
                            end else if (byte_ready) begin
                                data_reg1 <= shift_reg_in;
                                state <= STATE_DATA1;
                            end
                        end

                        CMD_READ_STATUS: begin
                            shift_reg_out <= {status_ready, status_error, status_prog_done, 5'b00000};
                            state <= STATE_RESPOND;
                        end

                        CMD_FORM: begin
                            if (!prog_en) begin
                                status_error <= 1'b1;
                                state <= STATE_IDLE;
                            end else if (byte_ready) begin
                                data_reg1 <= shift_reg_in;
                                state <= STATE_FORM;
                            end
                        end

                        CMD_SET_TIMING: begin
                            if (byte_ready) begin
                                data_reg1 <= shift_reg_in;
                                state <= STATE_DATA1;
                            end
                        end

                        CMD_READ_CELL: begin
                            if (byte_ready) begin
                                data_reg1 <= shift_reg_in;
                                state <= STATE_READ_WAIT;
                            end
                        end

                        default: begin
                            status_error <= 1'b1;
                            state <= STATE_IDLE;
                        end
                    endcase
                end

                STATE_DATA1: begin
                    if (byte_ready) begin
                        data_reg2 <= shift_reg_in;
                        if (cmd_reg == CMD_SET_TIMING) begin
                            pulse_width <= {data_reg1, shift_reg_in};
                            state <= STATE_IDLE;
                            status_ready <= 1'b1;
                        end else begin
                            state <= STATE_PROG_PULSE;
                        end
                    end
                end

                STATE_EXECUTE: begin
                    case (cmd_reg)
                        CMD_SET_ROW: begin
                            row_drive <= data_reg1;
                            status_ready <= 1'b1;
                            state <= STATE_IDLE;
                        end
                        default: state <= STATE_IDLE;
                    endcase
                end

                STATE_PROG_PULSE: begin
                    status_prog_done <= 1'b0;
                    row_drive <= (data_reg1[1]) ?
                                 (8'b1 << data_reg1[7:5]) :
                                 ~(8'b1 << data_reg1[7:5]);
                    pulse_counter <= pulse_width * data_reg2;
                    state <= STATE_PROG_WAIT;
                end

                STATE_PROG_WAIT: begin
                    if (pulse_counter == 0) begin
                        row_drive <= 8'h00;
                        status_prog_done <= 1'b1;
                        status_ready <= 1'b1;
                        state <= STATE_IDLE;
                    end else begin
                        pulse_counter <= pulse_counter - 1'b1;
                    end
                end

                STATE_READ_WAIT: begin
                    row_drive <= (8'b1 << data_reg1[7:5]);
                    if (pulse_counter == 0) begin
                        pulse_counter <= 16'd10;
                    end else if (pulse_counter == 1) begin
                        last_col_read <= col_sense;
                        shift_reg_out <= col_sense;
                        row_drive <= 8'h00;
                        state <= STATE_RESPOND;
                        pulse_counter <= 16'd0;
                    end else begin
                        pulse_counter <= pulse_counter - 1'b1;
                    end
                end

                STATE_FORM: begin
                    row_drive <= (8'b1 << data_reg1[7:5]);
                    pulse_counter <= form_width;
                    state <= STATE_PROG_WAIT;
                end

                STATE_RESPOND: begin
                    if (cs_d2) begin
                        status_ready <= 1'b1;
                        state <= STATE_IDLE;
                    end
                end

                default: state <= STATE_IDLE;

            endcase

            if (cs_falling) begin
                status_error <= 1'b0;
            end
        end
    end

endmodule
