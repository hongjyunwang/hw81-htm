/*
 * Each core will have its own instantiation of the l1 module
 */

module l1 #(
    parameter NUM_CORES = 2,
    parameter CORE_ID_BITS = 1,

    parameter CACHE_ENTRIES_PER_CORE = 32, // 32 cache entries per core
    parameter CACHE_LINE_SIZE = 64, // 64 bytes per cache line
    parameter ADDR_WIDTH = 32
)(
    input wire clk_i,
    input wire reset_i,

    // Input from the processor
    input wire cpu_valid_i, // a real cpu request is present
    input [ADDR_WIDTH-1:0] addr_i, // address from CPU request
    input req_i, // 0: ld, 1: sd
    input [CORE_ID_BITS-1:0] core_i, // The requesting core

    // Input from the directory controller
    input l1_ready_i, // Signaled when data is ready to be sent to cpu
    input invalidate_i, // TODO: Figure out wiring?
    input ACK_i, // TODO: Figure out wiring?
    input [(8*CACHE_LINE_SIZE)-1:0] l1_data_i, // Fetched complete cache line

    // Output to the processor
    output [CACHE_LINE_SIZE-1:0] cpu_data_o, // data byte to output to the CPU

    // Output to the directory controller
    output reg dir_valid_o // tells directory a real request is present
    output wire [CORE_ID_BITS-1:0] core_o, // The core doing the request
    output wire [ADDR_WIDTH-1:0] addr_o, // address sent down to directory controller
    output reg [2:0] coh_req_o
);

// ================ Derived Parameters ================
localparam OFFSET_BITS = $clog2(CACHE_LINE_SIZE); // Byte-offset bits in cache line
localparam INDEX_BITS = $clog2(CACHE_ENTRIES_PER_CORE); // Index into each directory entry
localparam TAG_BITS = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS;
localparam CACHE_ENTRY_BITS = TAG_BITS + 3 + 8*CACHE_LINE_SIZE;
// Bit masks to parse input address
localparam [ADDR_WIDTH-1:0] OFFSET_MASK = (1 << OFFSET_BITS) - 1;
localparam [ADDR_WIDTH-1:0] INDEX_MASK = ((1 << INDEX_BITS) - 1) << OFFSET_BITS;
localparam [ADDR_WIDTH-1:0] TAG_MASK = ((1 << TAG_BITS) - 1) << (OFFSET_BITS + INDEX_BITS);

// ================ Request Types ================
localparam REQ_LD_HIT = 3'b000;
localparam REQ_LD_MISS = 3'b001;
localparam REQ_SD_HIT  = 3'b010;
localparam REQ_SD_MISS = 3'b100;

// ================ Load and Store Request Types ================
localparam LOAD_REQ = 0;
localparam STORE_REQ = 1;

// ================ One-hot MSI State encoding ================
localparam [2:0] STATE_I = 3'b001; // Invalid
localparam [2:0] STATE_S = 3'b010; // Shared
localparam [2:0] STATE_M = 3'b100; // Modified

// ================ Internal Storage (Cache Line Entries) ================
// [tag bits | state bits | transaction bit | data bits]
reg [CACHE_ENTRY_BITS-1:0] entries [CACHE_ENTRIES_PER_CORE-1:0];
reg hit; // hit marker

// ================ Wires for Address Parsing and Argument Passing ================
wire [TAG_BITS-1:0] tags;
wire [INDEX_BITS-1:0] index;
wire [OFFSET_BITS-1:0] offset;
assign tag = (addr_i & TAG_MASK) >> (OFFSET_BITS + INDEX_BITS);
assign index = (addr_i & INDEX_MASK) >> OFFSET_BITS;
assign offset = addr_i & OFFSET_MASK;
assign addr_o = addr_i; // Pass down requested address and core
assign core_o = core_i; // Pass down requesting CPU information

always@(*) begin

    // Default to load hit
    coh_req_o = REQ_LD_HIT;

    // Check if tag bits match and line is valid
    wire [1:0] cached_state = entries[index][CACHE_ENTRY_BITS-TAG_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS-2];
    if (entries[index][CACHE_ENTRY_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS] == tags && cached_state != STATE_I)
        hit = 1;
    else
        hit = 0;

    case(req_i)
        LOAD_REQ:
            if(!hit)
                coh_req_o = REQ_LD_MISS;
        STORE_REQ:
            coh_req_o = (hit) ? REQ_SD_HIT : REQ_SD_MISS;
        default: 
            coh_req_o = REQ_LD_HIT;
    endcase

end

always @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        dir_valid_o <= 0; // No valid request downwards
    end else begin
        dir_valid_o <= cpu_valid_i;

        // Directory has acknowledged and returned data
        // TODO: How should we deal with this
        if (ACK_i) begin
            entries[index][CACHE_ENTRY_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS] <= tags;
            entries[index][CACHE_ENTRY_BITS-TAG_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS-3] <= STATE_S;
            entries[index][LINE_WIDTH-1:0] <= l1_data_i;
        end

        // Directory is telling us to invalidate this line
        // TODO: How should we deal with this
        if (invalidate_i) begin
            entries[index][CACHE_ENTRY_BITS-TAG_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS-3] <= STATE_I;
        end
    end
end

endmodule