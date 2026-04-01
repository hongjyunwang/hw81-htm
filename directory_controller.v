// Assuming serial requests and handling, no parallel execution

module directory_controller #(
    parameter NUM_CORES = 2,
    parameter CORE_ID_BITS = 1, // number of bits representing cores (2^N cores total)

    parameter CACHE_ENTRIES_PER_CORE = 32,
    parameter CACHE_LINE_SIZE = 64, // 64 bytes per cache line
    parameter ADDR_WIDTH = 32 // 32-bit addresses

    // Address parsing
    parameter OFFSET_BITS = $clog2(CACHE_LINE_SIZE); // Byte-offset bits in cache line
    parameter INDEX_BITS = $clog2(CACHE_ENTRIES_PER_CORE); // Index into each directory entry
    parameter TAG_BITS = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS;
    // Cache line entry
    parameter LINE_WIDTH = 8 * CACHE_LINE_SIZE; // Number of data bits in a cache line
    parameter CACHE_ENTRY_BITS = TAG_BITS + 3 + LINE_WIDTH;
)(
    input wire clk_i,
    input wire reset_i,
    
    // input wire transaction_i,
    // input wire tx_begin_i,
    // input wire tx_end_i,

    // Input from L1 cache
    input wire l1_signal_i, // Handshake: L1 is presenting a real coherent request
    input wire [NUM_CORES-1:0] core_i, // The core doing the request (one hot)
    input wire [2:0] coh_req_i,
    input wire [ADDR_WIDTH-1:0] addr_i, // address from coherence request
    output reg [(8*CACHE_LINE_SIZE)-1:0] l1_data_o, // Complete cache line being written downward (just data portion)

    // Input from L2
    input wire l2_signal_i, // Handshake: L2 has data ready
    input wire [(8*CACHE_LINE_SIZE)-1:0] mem_rdata_i, // Complete cache line returned from lower memory

    // Output to L1 cache
    output reg l1_signal_o, // Handshake: Ready signal for data
    output reg [CORE_ID_BITS-1:0] l1_core_o, // Target core for data
    output reg [(8*CACHE_LINE_SIZE)-1:0] l1_data_o, // Fetched complete cache line
    output reg l1_inv_signal_o, // Invalidate signal
    output reg [CORE_ID_BITS-1:0] l1_inv_core_o, // Target core for invalidate signal
    // Dont need to pass down type of downgrade bc that can be inferred from the request type

    // Output to L2    
    output reg l2_req_o, // Making downward memory request
    output reg l2_we_o, // 1 = write req, 0 = read req
    output reg [ADDR_WIDTH-1:0] mem_addr_o, // Data address to fetch
    output reg [(8*CACHE_LINE_SIZE)-1:0] l2_data_o // Complete cache line being written downward (just data portion)
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

// ================ One-hot State encoding ================
localparam [2:0] STATE_I = 3'b001; // Invalid
localparam [2:0] STATE_S = 3'b010; // Shared
localparam [2:0] STATE_M = 3'b100; // Modified
localparam [2:0] STATE_MX = 3'b011; // M, fetch/invalidate in flight
localparam [2:0] STATE_WAITING_L2 = 3'b101;

// ================ Directory Entry Layout ================
// [tag (20 bits) | state (3 bits) | Π presence vector (CORE_ID_BITS bits)]
localparam ENTRY_WIDTH = TAG_BITS + 3 + CORE_ID_BITS;
localparam T_IDX = NUM_CORES;
localparam STATE_HI = CORE_ID_BITS + 2;
localparam STATE_LO = CORE_ID_BITS;

// ================ Request Types ================
localparam REQ_LD_HIT = 3'b000;
localparam REQ_LD_MISS = 3'b001;
localparam REQ_SD_HIT  = 3'b010;
localparam REQ_SD_MISS = 3'b100;

// ================ FSM states and modes ================
localparam [3:0]
    S_IDLE = 4'd0, // Waiting for a new request
    S_PROCESS = 4'd1, // Read directory, decide action
    S_LD_HIT = 4'd2,
    S_LD_MISS = 4'd3,
    S_SD_MISS = 4'd4,
    S_SD_HIT = 4'd5;

localparam NORMAL_MODE = 1'b0;
localparam TRANSACTION_MODE = 1'b1;



// ================ Internal Storage and Wiring ================
reg [ENTRY_WIDTH-1:0] directory [0:NUM_ENTRIES-1];
reg [3:0] state;
// reg [NUM_CORES-1:0] in_transaction;  // 1 bit per core

// Latched request fields — stable across all FSM states for this request
reg [NUM_CORES-1:0] req_core;
reg [NUM_CORES-1:0] core_state; // Core status tracking
reg [2:0] req_type;
reg [ADDR_WIDTH-1:0] req_addr;
reg [ENTRY_WIDTH-1:0] cur_entry; // store Snapshot of the directory entry taken at S_LOOKUP
reg [LINE_WIDTH-1:0] fetched_line; // store Cache line returned from memory

wire [2:0] cur_state = cur_entry[STATE_HI:STATE_LO]; // current directory entry's state bits
wire [NUM_CORES-1:0] cur_pi = cur_entry[NUM_CORES-1:0]; // curren directory entry's tag bits
// Directory index: bits above the cache-line offset
wire [INDEX_BITS-1:0] dir_idx = req_addr[OFFSET_BITS + INDEX_BITS - 1 : OFFSET_BITS];


















always @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        // reset all registers and outputs

    end else begin
        // default output pulses low every cycle

        // transaction bit-vector tracking (tx_begin_i / tx_end_i)

        case (state)

            S_IDLE: begin
                if (l1_signal_i) begin
                    // Latch the request fields stably for the rest of the FSM
                    req_core <= core_i;
                    req_type <= coh_req_i;
                    req_addr <= addr_i;
                    cur_entry <= directory[dir_idx];
                    state <= S_PROCESS;
                end
            end
            S_PROCESS: begin
                // Determine next state
                case(req_type)
                    REQ_LD_HIT:
                        state <= S_LD_HIT;
                    REQ_LD_MISS:
                        state <= S_LD_MISS;
                    REQ_SD_HIT:
                        state <= S_SD_HIT;
                    REQ_SD_MISS:
                        state <= S_SD_MISS;
                endcase
            end

            S_LD_HIT:  begin
                // Should never transition into this state
            end

            S_LD_MISS: begin
                // Check whether the requested block is in the M state in another cache (the owner)
                if(cur_entry[CORE_ID_BITS-1:0] == 0) begin
                    // No owner, fetch data from L2
                    l2_req_o <= 1;
                    l2_we_o <= 0;
                    mem_addr_o <= req_addr;
                    state <= STATE_WAITING_L2;
                end else begin
                    // NOTE CONCURRENCY ISSUE (no more?)
                    // There is an owner, owner downgrades its L1 state to S (send out invalidate)
                    l1_inv_core_o <= cur_entry[CORE_ID_BITS-1:0];
                    l1_inv_signal_o <= 1;
                    
                    // Write the OWNER's line to L2
                    l2_req_o <= 1;
                    l2_we_o <= 1;
                    l2_data_o <= l1_data_o;
                end
            end
            S_SD_MISS: begin
            
            end
            S_SD_HIT: begin
            
            end

            STATE_WAITING_L2: begin
                // Block until data from L2 is fetched
                if(l2_signal_i) begin
                    // Pass to L1 if received signal
                    l1_signal_o <= 1;
                    l1_core_o <= req_core;
                    l1_data_o <= mem_rdata_i;
                    state <= S_IDLE; // completed coherent request
                end else begin
                    state <= STATE_WAITING_L2;
                end
            end



            default: state <= S_IDLE;

        endcase
    end
end


endmodule