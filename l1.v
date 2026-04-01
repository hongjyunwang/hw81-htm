/*
 * Each core will have its own instantiation of the l1 module
 */

// TODO: Handle state downgrading based on signals l1_inv_signal_i, l1_inv_core_i
// TODO: Actually need an ACK signal to notify the completion of a coherence request (governed by completion of some operation in L1, so will prolly be implemented here)

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
    input wire cpu_signal_i, // Handshake: a real cpu request is present
    input [ADDR_WIDTH-1:0] addr_i, // address from CPU request
    input req_i, // 0: ld, 1: sd
    input [CORE_ID_BITS-1:0] core_i, // The requesting core

    // Input from the directory controller
    input dc_signal_i, // Handshake: signaled when data is ready to be sent to cpu (ACK in paper)
    input invalidate_i,
    input [(8*CACHE_LINE_SIZE)-1:0] l1_data_i, // Fetched complete cache line
    input l1_inv_signal_i, // Invalidate signal
    input [CORE_ID_BITS-1:0] l1_inv_core_i, // Target core for invalidate signal

    // Output to the processor
    output wire cpu_ready_o, // Handshake: CPU can issue a new request when high
    output reg cpu_signal_o, // Handshake: data is ready to be sent to CPU
    output reg [(8*CACHE_LINE_SIZE)-1:0] cpu_data_o, // cache line output to the CPU

    // Output to the directory controller
    output reg dc_signal_o, // Handshake: tells directory a real request is present
    output wire [NUM_CORES-1:0] core_o, // The core doing the request (one hot)
    output wire [ADDR_WIDTH-1:0] addr_o, // address sent down to directory controller
    output reg [2:0] coh_req_o
    output reg [(8*CACHE_LINE_SIZE)-1:0] l2_data_o; // data to pass to L2 for writeback
);

// ================ Derived Parameters ================
// Address parsing
localparam OFFSET_BITS = $clog2(CACHE_LINE_SIZE); // Byte-offset bits in cache line
localparam INDEX_BITS  = $clog2(CACHE_ENTRIES_PER_CORE); // Index into each directory entry
localparam TAG_BITS = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS;
// Cache line entry
localparam LINE_WIDTH = 8 * CACHE_LINE_SIZE; // Number of data bits in a cache line
localparam CACHE_ENTRY_BITS = TAG_BITS + 3 + LINE_WIDTH;
// Bit masks to parse input address
localparam [ADDR_WIDTH-1:0] OFFSET_MASK = (1 << OFFSET_BITS) - 1;
localparam [ADDR_WIDTH-1:0] INDEX_MASK = ((1 << INDEX_BITS) - 1) << OFFSET_BITS;
localparam [ADDR_WIDTH-1:0] TAG_MASK = ((1 << TAG_BITS) - 1) << (OFFSET_BITS + INDEX_BITS);

// ================ Request Types ================
localparam REQ_LD_HIT = 3'b000;
localparam REQ_LD_MISS = 3'b001;
localparam REQ_SD_HIT = 3'b010;
localparam REQ_SD_MISS = 3'b100;

// ================ Load and Store Request Types ================
localparam LOAD_REQ = 0;
localparam STORE_REQ = 1;

// ================ One-hot MSI State encoding ================
localparam [2:0] STATE_I = 3'b001; // Invalid
localparam [2:0] STATE_S = 3'b010; // Shared
localparam [2:0] STATE_M = 3'b100; // Modified

// ================ FSM States ================
localparam L1_IDLE = 1'b0; // Ready to accept a new CPU request
localparam L1_WAIT = 1'b1; // Waiting on directory to service a miss

// ================ Internal Storage (Cache Line Entries) ================
// [tag bits | state bits | data bits]
reg [CACHE_ENTRY_BITS-1:0] entries [CACHE_ENTRIES_PER_CORE-1:0];

// ================ FSM State Register ================
// Essentially makes L1 accesses blocking for each core
reg l1_state;

// ================ Latched Miss Fields ================
// Held stable for the entire L1_WAIT period
reg [TAG_BITS-1:0] latched_tags;
reg [INDEX_BITS-1:0] latched_index;
reg latched_req;

// ================ Wires for Address Parsing ================
wire [TAG_BITS-1:0] tags;
wire [INDEX_BITS-1:0] index;
wire [OFFSET_BITS-1:0] offset;
assign tags = (addr_i & TAG_MASK) >> (OFFSET_BITS + INDEX_BITS);
assign index  = (addr_i & INDEX_MASK) >> OFFSET_BITS;
assign offset = addr_i & OFFSET_MASK;
// Pass through to directory
assign addr_o = addr_i;
assign core_o = core_i;
// CPU can issue a new request only when IDLE
assign cpu_ready_o = (l1_state == L1_IDLE);

// ================ Cached State Slice ================
wire [2:0] cached_state = entries[index][CACHE_ENTRY_BITS-TAG_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS-3];

// ================ Hit Detection (combinational) ================
wire hit = (entries[index][CACHE_ENTRY_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS] == tags) && (cached_state != STATE_I);

// ================ Combinational Block ================
// Determine request
always @(*) begin
    coh_req_o = REQ_LD_HIT; // default

    // Only evaluate requests when IDLE and a real CPU request is present
    if (l1_state == L1_IDLE && cpu_signal_i) begin
        case (req_i)
            LOAD_REQ:
                if (!hit) coh_req_o = REQ_LD_MISS;
            STORE_REQ:
                coh_req_o = hit ? REQ_SD_HIT : REQ_SD_MISS;
            default:
                coh_req_o = REQ_LD_HIT;
        endcase
    end
end

// ================ Sequential Block ================
always @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        l1_state <= L1_IDLE;
        dc_signal_o  <= 0;
        cpu_signal_o <= 0;
        cpu_data_o <= 0;
        latched_tags <= 0;
        latched_index <= 0;
        latched_req <= 0;
    end else begin
        // Default all output pulses low each cycle
        dc_signal_o <= 0;
        cpu_signal_o <= 0;

        case (l1_state)
            L1_IDLE: begin
                // Respond to cpu input and send data to controller only on IDLE
                if (cpu_signal_i) begin
                    if (hit) begin
                        // Hit: serve directly from cache, no need to go to directory
                        cpu_signal_o <= 1;
                        cpu_data_o <= entries[index][LINE_WIDTH-1:0];
                    end else begin
                        // Miss: latch request fields and forward to directory
                        latched_tags <= tags;
                        latched_index <= index;
                        latched_req <= req_i;
                        dc_signal_o <= 1;
                        l1_state <= L1_WAIT;
                        l2_data_o <= entries[index][LINE_WIDTH-1:0]; // pass data down
                    end
                end
            end
            L1_WAIT: begin
                // Block all new CPU requests until the miss is resolved
                // dc_signal_i should only be sent in L1_WAIT state
                if (dc_signal_i) begin
                    // Fill the cache entry using latched fields
                    entries[latched_index][CACHE_ENTRY_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS] <= latched_tags;
                    entries[latched_index][CACHE_ENTRY_BITS-TAG_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS-3] <= (latched_req == STORE_REQ) ? STATE_M : STATE_S;
                    entries[latched_index][LINE_WIDTH-1:0] <= l1_data_i;
                    // Return data to CPU
                    cpu_signal_o <= 1;
                    cpu_data_o <= l1_data_i;
                    l1_state <= L1_IDLE;
                end
            end
        endcase

        // Invalidation can arrive in either state
        if (invalidate_i) begin
            entries[index][CACHE_ENTRY_BITS-TAG_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS-3] <= STATE_I;
        end
    end
end

endmodule