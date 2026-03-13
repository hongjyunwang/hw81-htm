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
    input wire [(8*CACHE_LINE_SIZE)-1:0] mem_rdata_i, // Cache line returned from lower memory
    output reg mem_req_o, // Making downward memory request
    output reg mem_we_o, // 0 = write req, 1 = read req
    output reg [ADDR_WIDTH-1:0] mem_addr_o, // Data address to fetch
    output reg [(8*CACHE_LINE_SIZE)-1:0] mem_wdata_o, // Cache line being written downward

    // Upward fetch/return interface with L1
    output reg l1_ready_o, // Ready signal
    output reg [N-1:0] l1_core_o, // Target core
    output reg [(8*CACHE_LINE_SIZE)-1:0] l1_data_o, // Fetched cache line
    output invalidate_o,
    output ACK_o
);

// ================ Derived Parameters ================
localparam LINE_WIDTH  = 8 * CACHE_LINE_SIZE;
localparam NUM_CORES = (1 << N); // 2^N total cores
localparam OFFSET_BITS = $clog2(CACHE_LINE_SIZE); // Byte-offset bits in cache line
localparam INDEX_BITS  = $clog2(NUM_ENTRIES); // Index into each directory entry


// ================ Directory Entry Layout ================
// [ state (3 bits) | T (1 bit) | Π presence vector (NUM_CORES bits) ]
localparam ENTRY_WIDTH = NUM_CORES + 3 + 1;
// Field positions
localparam STATE_LO = NUM_CORES + 1; // state LSB
localparam STATE_HI = NUM_CORES + 3; // state MSB
localparam T_IDX = NUM_CORES;
// One-hot state encoding
localparam [2:0] STATE_I = 3'b001; // Invalid
localparam [2:0] STATE_S = 3'b010; // Shared
localparam [2:0] STATE_M = 3'b100; // Modified


// ================ Request Types ================
localparam REQ_LD_MISS = 2'b00;
localparam REQ_SD_MISS = 2'b01;
localparam REQ_SD_HIT  = 2'b10;

// ================ FSM states and modes ================
localparam [3:0]
    S_IDLE      = 4'd0, // Waiting for a new request
    S_LOOKUP    = 4'd1, // Read directory, decide action
    S_INV_SEND  = 4'd2, // Send INV to each S-state sharer (one per cycle)
    S_OWNER_INV = 4'd3, // Send INV/writeback request to M-state owner
    S_OWNER_WB  = 4'd4, // One-cycle writeback propagation window
    S_MEM_WAIT  = 4'd5, // Waiting for memory read to return
    S_RESPOND   = 4'd6; // Send data + ACK to requesting L1

localparam NORMAL_MODE      = 1'b0;
localparam TRANSACTION_MODE = 1'b1;
 

// ================ Storage ================
reg [ENTRY_WIDTH-1:0] directory [0:NUM_ENTRIES-1];
reg [NUM_CORES-1:0] in_transaction;  // 1 bit per core
reg [3:0] state;
 
// Latched request fields — stable across all FSM states for this request
reg [N-1:0] req_core;
reg [1:0] req_type;
reg [ADDR_WIDTH-1:0] req_addr;
 
// Snapshot of the directory entry taken at S_LOOKUP
reg [ENTRY_WIDTH-1:0] cur_entry;
// Bitmask of cores that still need an INV pulse
reg [NUM_CORES-1:0] inv_pending;
// Cache line returned from memory; held until S_RESPOND
reg [LINE_WIDTH-1:0] fetched_line;


// ================ Combinational helpers ================ 
wire [2:0] cur_state = cur_entry[STATE_HI:STATE_LO]; // current directory entry's state bits
wire [NUM_CORES-1:0] cur_pi = cur_entry[NUM_CORES-1:0]; // curren directory entry's tag bits

// Directory index: bits above the cache-line offset
wire [INDEX_BITS-1:0] dir_idx = req_addr[OFFSET_BITS + INDEX_BITS - 1 : OFFSET_BITS];
 
// Priority encoder
// inv_pending is a bitmask of cores that still need an INV sent to them. The goal is to pick one core per cycle to invalidate.
// This gives us the next core to send an INV to.
integer               k;
reg [N-1:0]           inv_next;
always @(*) begin
    inv_next = {N{1'b0}};
    for (k = NUM_CORES-1; k >= 0; k = k - 1)
        if (inv_pending[k]) inv_next = k[N-1:0];
end

// Build a one-hot presence-vector bit for a given core index
// Converts core ID to position in core bit mask to be used when writing into directory entry
function automatic [NUM_CORES-1:0] core_mask;
    input [N-1:0] core;
    core_mask = {{(NUM_CORES-1){1'b0}}, 1'b1} << core;
endfunction


always @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        // reset all registers and outputs

    end else begin
        // default output pulses low every cycle
        
        // transaction bit-vector tracking (tx_begin_i / tx_end_i)

        case (state)

            S_IDLE: begin
                // Waiting for a new request
            end

            S_LOOKUP: begin
                // Read directory, decide action
            end

            S_INV_SEND: begin
                // Send INV to each S-state sharer (one per cycle)
            end

            S_OWNER_INV: begin
                // Send INV/writeback request to M-state owner
            end

            S_OWNER_WB: begin
                // One-cycle writeback propagation window
            end

            S_MEM_WAIT: begin
                // Waiting for memory read to return
            end

            S_RESPOND: begin
                // Send data + ACK to requesting L1
            end

            default: state <= S_IDLE;

        endcase
    end
end


endmodule