// Assuming serial requests and handling, no parallel execution

module directory_controller #(
    parameter N = 1, // number of bits representing cores (2^N cores total)
    parameter NUM_ENTRIES = 64,
    parameter CACHE_LINE_SIZE = 64,
    parameter ADDR_WIDTH = 32
)(
    input wire clk_i;
    input wire reset_i;

    // Control signals
    input wire [N-1:0] core_i, // The core doing the request
    input wire [1:0] nomral_req_i // 00: ld_miss_i, 01: sd_miss_i, 10: sd_hit_i

    input wire transaction_i,
    input wire tx_begin_i,
    input wire tx_end_i,

    input wire [ADDR_WIDTH-1:0] addr_i, // address from coherence request
    
    // Downward fetch/return interface with mem
    input wire mem_ready_i, // Ready signal
    input wire [LINE_WIDTH-1:0] mem_rdata_i, // Cache line returned from lower memory
    output reg mem_req_o, // Making downward memory request
    output reg mem_we_o, // 0 = write req, 1 = read req
    output reg [ADDR_WIDTH-1:0] mem_addr_o, // Data address to fetch
    output reg [LINE_WIDTH-1:0] mem_wdata_o, // Cache line being written downward

    // Upward fetch/return interface with L1
    output reg l1_ready_o, // Ready signal
    output reg [N-1:0] l1_core_o, // Target core
    output reg [(8*CACHE_LINE_SIZE)-1:0] l1_data_o, // Fetched cache line
    output invalidate_o,
    output ACK_o
);

// Local values
localparam ENTRY_WIDTH = 3 + 1 + N;
localparam NORMAL_MODE = 0, TRANSACTION_MODE = 1;
localparam REQ_LD_MISS = 2'b00;
localparam REQ_SD_MISS = 2'b01;
localparam REQ_SD_HIT  = 2'b10;
reg [ENTRY_WIDTH-1:0] directory [0:NUM_ENTRIES-1];
reg [N-1:0] in_transaction; // inTransaction bit vector
reg mode; // current core mode

always@(*) begin
    
    case (nomral_req_i) 
        REQ_LD_MISS: begin
            // handle load miss
        end

        REQ_SD_MISS: begin
            // handle store miss
        end

        REQ_SD_HIT: begin
            // handle store hit (upgrade)
        end
    endcase

end

always@(posedge clk_i) begin
    
end


endmodule