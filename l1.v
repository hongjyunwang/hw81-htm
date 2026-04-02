/*
 * Each core will have its own instantiation of the l1 module
 */

// TODO: Actually need an ACK signal to notify the completion of a coherence request (governed by completion of some operation in L1, so will prolly be implemented here)

module l1 #(
    parameter CORE_ID,
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
    input dc_signal_i, // Handshake: signaled when data is sent in from the directory controller
    input [(8*CACHE_LINE_SIZE)-1:0] l1_data_i, // Fetched cache line
    input [1:0] dg_signal_i, // Invalidate signal
    input [CORE_ID_BITS-1:0] l1_dg_core_i, // Target core for invalidate signal
    input [ADDR_WIDTH-1:0] l1_dg_addr_i, // Target address to be downgraded

    // Output to the processor
    output wire cpu_ready_o, // Handshake: CPU can issue a new request when high
    output reg cpu_signal_o, // Handshake: data is ready to be sent to CPU
    output reg [(8*CACHE_LINE_SIZE)-1:0] cpu_data_o, // cache line output to the CPU

    // Output to the directory controller
    output reg dc_signal_o, // Handshake: tells directory a real request is present
    output wire [NUM_CORES-1:0] core_o, // The core doing the request (one hot)
    output wire [ADDR_WIDTH-1:0] addr_o, // address sent down to directory controller
    output reg [2:0] coh_req_o,
    output wire [(8*CACHE_LINE_SIZE)-1:0] l2_data_o, // data to pass to L2 for writeback
    output wire l1_dg_ack_o // acknowledge that the downgrade has been completed
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

// ================ Latches ================
// Held stable for the entire L1_WAIT period
reg [INDEX_BITS-1:0] latched_index;
reg [TAG_BITS-1:0] latched_tags;
reg latched_req;

// ================ Wires for Address Parsing ================
wire [TAG_BITS-1:0] tags = (addr_i & TAG_MASK) >> (OFFSET_BITS + INDEX_BITS);
wire [INDEX_BITS-1:0] index = (addr_i & INDEX_MASK) >> OFFSET_BITS;
wire [OFFSET_BITS-1:0] offset = addr_i & OFFSET_MASK;

// ================ Wiring to Directory Controller ================
assign addr_o = addr_i;
assign core_o = core_i;

// ================ Hit Detection ================
wire [2:0] cached_state = entries[index][CACHE_ENTRY_BITS-TAG_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS-3];
wire hit = (entries[index][CACHE_ENTRY_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS] == tags) && (cached_state != STATE_I);



// CPU can issue a new request only when IDLE
assign cpu_ready_o = (l1_state == L1_IDLE);




// ================ Combinational Block ================
// Determine request
always @(*) begin
    coh_req_o = REQ_LD_HIT; // default

    // Only evaluate requests when IDLE and a real CPU request is present
    if (l1_state == L1_IDLE && cpu_signal_i) begin
        case (req_i)
            LOAD_REQ:
                if (!hit)
                    coh_req_o = REQ_LD_MISS;
            STORE_REQ:
                coh_req_o = hit ? REQ_SD_HIT : REQ_SD_MISS;
            default:
                coh_req_o = REQ_LD_HIT;
        endcase
    end
end


wire [INDEX_BITS-1:0] dg_index = (l1_dg_addr_i & INDEX_MASK) >> OFFSET_BITS;
assign l1_dg_ack_o = dg_signal_i && ((core_i & l1_dg_core_i) != 0); // driven on 
assign l2_data_o = (dg_signal_i && (core_i & l1_dg_core_i != 0)) ? entries[dg_index][LINE_WIDTH-1:0] : 0; // driven on downgrade signal
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
                        latched_index <= index;
                        latched_tags <= tags;
                        latched_req <= req_i;
                        
                        // Signal directory to take action
                        dc_signal_o <= 1;

                        // Set next state
                        l1_state <= L1_WAIT;
                    end
                end
            end
            L1_WAIT: begin
                // Block all new CPU requests until the miss is resolved
                // dc_signal_i should only be sent in L1_WAIT state
                if (dc_signal_i) begin

                    // Write in fetched data
                    entries[latched_index][LINE_WIDTH-1:0] <= l1_data_i;

                    // Fill the cache entry using latched fields
                    entries[latched_index][CACHE_ENTRY_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS] <= latched_tags;
                    entries[latched_index][CACHE_ENTRY_BITS-TAG_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS-3] <= (latched_req == STORE_REQ) ? STATE_M : STATE_S;

                    // Return data to CPU
                    cpu_signal_o <= 1;
                    cpu_data_o <= l1_data_i;
                    // Ackowledge complete state downgrade
                    l1_state <= L1_IDLE;
                end
            end
        endcase

        // Downgrade and writeback operations
        // Confirm that the invalidate signal is sent and core_i is in l1_dg_core_i
        if (dg_signal_i && ((core_i & l1_dg_core_i) != 0)) begin
            if(dg_signal_i == 2'b01) begin // LD_MISS
                // downgrade to S
                entries[dg_index][CACHE_ENTRY_BITS-TAG_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS-3] <= STATE_S;
            end
            if(dg_signal_i == 2'b10) begin // SD_MISS Invalidate
                // downgrade to I
                entries[dg_index][CACHE_ENTRY_BITS-TAG_BITS-1 : CACHE_ENTRY_BITS-TAG_BITS-3] <= STATE_I;
            end
            if(dg_signal_i == 2'b11) begin // SD_HIT Invalidate

            end

        end
    end
end

endmodule