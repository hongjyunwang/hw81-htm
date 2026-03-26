// Assuming serial requests and handling, no parallel execution


// *Priority
// TODO: Build a simple strawman L1 cache would be helpful for testing and debugging (direct mapped)
// TODO: BUild a L2 cache as fownward main memory interface. This would be
// more complete and full-blown compared to the strawman L1. Use set associative and bigger size



module directory_controller #(
    parameter NUM_CORES = 2,
    parameter CORE_ID_BITS = 1, // number of bits representing cores (2^N cores total)

    parameter CACHE_ENTRIES_PER_CORE = 32,
    parameter CACHE_LINE_SIZE = 64, // 64 bytes per cache line
    parameter ADDR_WIDTH = 32 // 32-bit addresses
)(
    input wire clk_i;
    input wire reset_i;

    // Control signals
    input wire [CORE_ID_BITS-1:0] core_i, // The core doing the request
    input wire [1:0] nomral_req_i // 00: ld_miss_i, 01: sd_miss_i, 10: sd_hit_i

    // input wire transaction_i,
    // input wire tx_begin_i,
    // input wire tx_end_i,

    input wire [ADDR_WIDTH-1:0] addr_i, // address from coherence request

    // Downward fetch/return interface with mem (L2)
    input wire mem_ready_i, // Ready signal
    input wire [(8*CACHE_LINE_SIZE)-1:0] mem_rdata_i, // Complete cache line returned from lower memory
    output reg mem_req_o, // Making downward memory request
    output reg mem_we_o, // 0 = write req, 1 = read req
    output reg [ADDR_WIDTH-1:0] mem_addr_o, // Data address to fetch
    output reg [(8*CACHE_LINE_SIZE)-1:0] mem_wdata_o, // Complete cache line being written downward

    // Upward fetch/return interface with L1
    output reg l1_ready_o, // Ready signal
    output reg [CORE_ID_BITS-1:0] l1_core_o, // Target core
    output reg [(8*CACHE_LINE_SIZE)-1:0] l1_data_o, // Fetched complete cache line
    output invalidate_o,
    output ACK_o
);

// ================ Derived Parameters ================
localparam NUM_ENTRIES = NUM_CORES * CACHE_ENTRIES_PER_CORE; // Total number of directory entries
localparam LINE_WIDTH  = 8 * CACHE_LINE_SIZE;
localparam OFFSET_BITS = $clog2(CACHE_LINE_SIZE); // Byte-offset bits in cache line
localparam INDEX_BITS  = $clog2(NUM_ENTRIES); // Index into each directory entry
localparam TAG_BITS  = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS;

// ================ Directory Entry Layout ================
// [tag (20 bits) | state (2 bits) | Π presence vector (CORE_ID_BITS bits)]
localparam ENTRY_WIDTH = TAG_BITS + 2 + CORE_ID_BITS;
localparam T_IDX = NUM_CORES;

// ================ One-hot State encoding ================
localparam [1:0] STATE_I = 2'b01; // Invalid
localparam [1:0] STATE_S = 2'b10; // Shared
localparam [1:0] STATE_M = 2'b11; // Modified

// ================ Request Types ================
localparam REQ_LD_MISS = 2'b00;
localparam REQ_SD_MISS = 2'b01;
localparam REQ_SD_HIT  = 2'b10;


// ================ FSM states and modes ================
localparam [3:0]
    S_IDLE = 4'd0, // Waiting for a new request
    S_PROCESS = 4'd1, // Read directory, decide action
    S_LD_MISS = 4'd2;
    S_SD_MISS = 4'd3;
    S_SD_HIT = 4'd4;

localparam NORMAL_MODE = 1'b0;
localparam TRANSACTION_MODE = 1'b1;


// ================ Internal Storage ================
reg [ENTRY_WIDTH-1:0] directory [0:NUM_ENTRIES-1];
reg [NUM_CORES-1:0] in_transaction;  // 1 bit per core
reg [3:0] state;
 
// Latched request fields — stable across all FSM states for this request
reg [N-1:0] req_core;
reg [1:0] req_type;
reg [ADDR_WIDTH-1:0] req_addr;
 
// Snapshot of the directory entry taken at S_LOOKUP
reg [ENTRY_WIDTH-1:0] cur_entry;
// Cache line returned from memory
reg [LINE_WIDTH-1:0] fetched_line;


// ================ Combinational helpers ================ 
wire [2:0] cur_state = cur_entry[STATE_HI:STATE_LO]; // current directory entry's state bits
wire [NUM_CORES-1:0] cur_pi = cur_entry[NUM_CORES-1:0]; // curren directory entry's tag bits

// Directory index: bits above the cache-line offset
wire [INDEX_BITS-1:0] dir_idx = req_addr[OFFSET_BITS + INDEX_BITS - 1 : OFFSET_BITS];

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


            default: state <= S_IDLE;

        endcase
    end
end


endmodule