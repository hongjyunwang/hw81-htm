// Assuming serial requests and handling, no parallel execution

module directory_controller #(
    parameter NUM_CORES = 2,
    parameter CORE_ID_BITS = 1, // number of bits representing cores (2^N cores total)

    parameter CACHE_ENTRIES_PER_CORE = 32,
    parameter CACHE_LINE_SIZE = 64, // 64 bytes per cache line
    parameter ADDR_WIDTH = 32 // 32-bit addresses
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
    input wire [(8*CACHE_LINE_SIZE)-1:0] l1_data_i, // Complete cache line being written downward to l2 (just data portion)
    input wire l1_dg_ack_i, // acknowledge that the downgrade has been completed

    // Input from L2
    input wire l2_signal_i, // Handshake: L2 has data ready
    input wire [(8*CACHE_LINE_SIZE)-1:0] mem_rdata_i, // Complete cache line returned from lower memory

    // Output to L1 cache
    output reg l1_signal_o, // Handshake: Ready signal for data, meaning controller finished its tasks (I think this is the ACK?)
    output reg [CORE_ID_BITS-1:0] l1_core_o, // Target core for data
    output reg [(8*CACHE_LINE_SIZE)-1:0] l1_data_o, // Fetched complete cache line
    output reg [1:0] l1_dg_signal_o, // Downgrade signal
    // l1_dg_signal_o: 00 -> no signal, 01 -> LD_MISS (downgrade to S), 10 -> SD_MISS (invalidate), 11 -> SD_HIT (invalidate)
    output reg [CORE_ID_BITS-1:0] l1_dg_core_o, // Target core for invalidate signal
    output wire [ADDR_WIDTH-1:0] l1_dg_addr_o, // Target address to be downgraded

    // Output to L2    
    output reg l2_req_o, // Making downward memory request
    output reg l2_we_o, // 1 = write req, 0 = read req
    output reg [ADDR_WIDTH-1:0] mem_addr_o, // Data address to fetch
    output wire [(8*CACHE_LINE_SIZE)-1:0] l2_data_o // Complete cache line being written downward to l2 (just data portion)
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

localparam NUM_ENTRIES = NUM_CORES * CACHE_ENTRIES_PER_CORE;

// ================ One-hot State encoding ================
localparam [2:0] STATE_I = 3'b001; // Invalid
localparam [2:0] STATE_S = 3'b010; // Shared
localparam [2:0] STATE_M = 3'b100; // Modified


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
    S_SD_HIT = 4'd5,
    S_WAITING_OWNER  = 4'd6,
    S_WAITING_L2 = 4'd7;

localparam NORMAL_MODE = 1'b0;
localparam TRANSACTION_MODE = 1'b1;



// ================ Internal Storage and Wiring ================
reg [ENTRY_WIDTH-1:0] directory [NUM_ENTRIES-1:0];
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

// data to write down to l2
// note that writeback to l2 only happens when a miss happens and an owner writes data back
assign l2_data_o = l1_data_i;
assign l1_dg_addr_o = req_addr;

reg [3:0] prev_state;
integer j;
always @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        state <= S_IDLE;
        l2_req_o <= 0;
        l2_we_o <= 0;
        mem_addr_o <= 0;
        l1_signal_o <= 0;
        l1_core_o <= 0;
        l1_data_o <= 0;
        l1_dg_signal_o <= 2'b00;
        l1_dg_core_o <= 0;
        req_core <= 0;
        req_type <= 0;
        req_addr <= 0;
        cur_entry <= 0;
        fetched_line <= 0;
        for (j = 0; j < NUM_ENTRIES; j = j + 1)
            directory[j] <= 0;
    end else begin
        // default output pulses low every cycle
        l2_req_o <= 0;
        l2_we_o <= 0;
        l1_signal_o <= 0;
        l1_dg_signal_o <= 2'b00;

        if (state != prev_state) begin
            $display("[DC tick] state transition: %0d -> %0d", prev_state, state);
            prev_state <= state;
        end

        // transaction bit-vector tracking (tx_begin_i / tx_end_i)

        case (state)

            S_IDLE: begin
                if (l1_signal_i) begin
                    // Latch the request fields stably for the rest of the FSM
                    req_core <= core_i;
                    req_type <= coh_req_i;
                    req_addr <= addr_i;
                    cur_entry <= directory[addr_i[OFFSET_BITS + INDEX_BITS - 1 : OFFSET_BITS]]; // reads directly from addr_i
                    state <= S_PROCESS;

                    $strobe("[DC S_IDLE] latched: req_core=%b req_type=%b req_addr=0x%h cur_pi=%b cur_state=%b",
                        req_core, req_type, req_addr,
                        cur_entry[NUM_CORES-1:0],
                        cur_entry[STATE_HI:STATE_LO]);
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

                $display("[DC S_PROCESS] req_type=%b -> next_state=%s  cur_pi=%b cur_state=%b",
                    req_type,
                    (req_type == REQ_LD_HIT)  ? "S_LD_HIT"  :
                    (req_type == REQ_LD_MISS) ? "S_LD_MISS" :
                    (req_type == REQ_SD_HIT)  ? "S_SD_HIT"  :
                    (req_type == REQ_SD_MISS) ? "S_SD_MISS" : "UNKNOWN",
                    cur_entry[NUM_CORES-1:0],
                    cur_entry[STATE_HI:STATE_LO]);
            end

            S_LD_HIT:  begin
                // Should never transition into this state
            end

            S_LD_MISS: begin
                // Check whether the requested block is in the M state in another cache (the owner)
                if(cur_entry[CORE_ID_BITS-1:0] == 0) begin
                    // No owner, fetch data from L2
                    l2_req_o <= 1;
                    l2_we_o <= 0; // read request
                    mem_addr_o <= req_addr;
                    state <= S_WAITING_L2;
                    $display("[DC S_LD_MISS] transitioning to S_WAITING_L2");
                end else begin
                    // There is an owner, owner downgrades its L1 state to S (send out invalidate)
                    l1_dg_core_o <= cur_entry[CORE_ID_BITS-1:0];
                    l1_dg_signal_o <= 2'b01; // downgrade to S
                    state <= S_WAITING_OWNER;
                end

                $display("[DC S_LD_MISS] cur_pi=%b cur_state=%b -> %s",
                    cur_entry[NUM_CORES-1:0],
                    cur_entry[STATE_HI:STATE_LO],
                    (cur_entry[NUM_CORES-1:0] == 0) ? "no owner, fetching from L2" : "owner exists, sending downgrade");
            end
            S_SD_MISS: begin
                // Check whether the requested block is in the M state in another cache (the owner)
                if(cur_entry[CORE_ID_BITS-1:0] == 0) begin
                    // No owner, fetch data from L2
                    l2_req_o <= 1;
                    l2_we_o <= 1; // write request
                    mem_addr_o <= req_addr;
                    state <= S_WAITING_L2;
                    $display("[DC S_SD_MISS] transitioning to S_WAITING_L2");
                end else begin
                    // There is an owner, owner downgrades its L1 state to S (send out invalidate)
                    l1_dg_core_o <= cur_entry[CORE_ID_BITS-1:0];
                    l1_dg_signal_o <= 2'b10; // downgrade to I
                    state <= S_WAITING_OWNER;
                end

                $display("[DC S_SD_MISS] cur_pi=%b cur_state=%b -> %s",
                    cur_entry[NUM_CORES-1:0],
                    cur_entry[STATE_HI:STATE_LO],
                    (cur_entry[NUM_CORES-1:0] == 0) ? "no owner, fetching from L2" : "owner exists, sending downgrade");
            end
            S_SD_HIT: begin
                
            end

            S_WAITING_OWNER: begin
                l1_dg_signal_o <= 2'b01; // held high each cycle until ack
                l1_dg_core_o <= cur_pi[CORE_ID_BITS-1:0];
                // Block until owner has completed operation
                if(l1_dg_ack_i) begin
                    // Write the OWNER's line to L2
                    l2_req_o <= 1;
                    l2_we_o <= 1; // write request
                    mem_addr_o <= req_addr;

                    // Owner must forward line to requester (current core)
                    l1_signal_o <= 1;
                    l1_core_o <= req_core;
                    l1_data_o <= l1_data_i; // routed from line owner, not l2

                    // Update directory entry metadata
                    directory[dir_idx][NUM_CORES-1:0] <= (req_type == REQ_SD_MISS) ? req_core : (cur_pi | req_core);
                    directory[dir_idx][STATE_HI:STATE_LO] <= (req_type == REQ_SD_MISS) ? STATE_M  : STATE_S;
                    
                    state <= S_IDLE; // completed coherent request
                end else begin
                    state <= S_WAITING_OWNER;
                end
            end

            S_WAITING_L2: begin
                // Block until data from L2 is fetched
                $display("[DC S_WAITING_L2] tick, l2_signal_i=%b", l2_signal_i);

                if(l2_signal_i) begin
                    // Pass fetched line to requesting L1
                    l1_signal_o <= 1;
                    l1_core_o <= req_core;
                    l1_data_o <= mem_rdata_i;
 
                    // Update directory
                    directory[dir_idx][NUM_CORES-1:0] <= req_core;
                    directory[dir_idx][STATE_HI:STATE_LO] <= (req_type == REQ_SD_MISS) ? STATE_M : STATE_S;
 
                    state <= S_IDLE;

                    $display("[S_WAITING_L2] Acquired data from L2");
                end else begin
                    state <= S_WAITING_L2;
                    $display("[S_WAITING_L2] Still Waiting");
                end
            end



            default: state <= S_IDLE;

        endcase
    end
end


endmodule