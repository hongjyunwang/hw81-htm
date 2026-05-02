// On the way back up: l1_ready_o, l1_data_o, ACK_o, invalidate_o from the directory need to be routed to the correct L1 instance based on l1_core_o

module top #(
    parameter NUM_CORES = 2,

    parameter CACHE_ENTRIES_PER_CORE = 32, // 32 cache entries per core
    parameter CACHE_LINE_SIZE = 64, // 64 bytes per cache line
    parameter ADDR_WIDTH = 32
)(
    input clk,
    input rst,

    // CPU-facing ports (one set of communication wires per core)
    // Note that these are flattened, need to process in the module to feed to the instantiations
    input wire [NUM_CORES-1:0] cpu_req_valid,
    input wire [NUM_CORES*ADDR_WIDTH-1:0] cpu_addr,
    input wire [NUM_CORES-1:0] cpu_req, // 0=ld, 1=sd per core

    output wire [NUM_CORES-1:0] cpu_ready,
    output wire [NUM_CORES-1:0] cpu_resp_valid,
    output wire [NUM_CORES*(8*CACHE_LINE_SIZE)-1:0] cpu_data,

    // L2-facing ports (single interface, not per core)
    input wire l2_signal_i,
    input wire [(8*CACHE_LINE_SIZE)-1:0] l2_rdata_i,

    output wire l2_req_o,
    output wire l2_we_o,
    output wire [ADDR_WIDTH-1:0] l2_addr_o,
    output wire [(8*CACHE_LINE_SIZE)-1:0] l2_wdata_o
);

// ================ Internal Wires between L1 and CPU ================
// CPU -> L1
wire cpu_l1_req_valid [NUM_CORES-1:0];
wire [ADDR_WIDTH-1:0] cpu_l1_addr [NUM_CORES-1:0];
wire cpu_l1_req [NUM_CORES-1:0];
wire [NUM_CORES-1:0] cpu_l1_core [NUM_CORES-1:0];
// L1 -> CPU
wire l1_cpu_ready [NUM_CORES-1:0];
wire l1_cpu_resp_valid [NUM_CORES-1:0];
wire [(8*CACHE_LINE_SIZE)-1:0] l1_cpu_data [NUM_CORES-1:0];

// ================ Parsing CPU facing ports ================
genvar i;
generate
    for (i = 0; i < NUM_CORES; i = i + 1) begin : CPU_PORT_PARSE
        // Unpack CPU -> L1 inputs
        assign cpu_l1_req_valid[i] = cpu_req_valid[i];
        assign cpu_l1_addr[i] = cpu_addr[i*ADDR_WIDTH +: ADDR_WIDTH];
        assign cpu_l1_req[i] = cpu_req[i];

        // Give each L1 its own one-hot core ID
        assign cpu_l1_core[i] = (1'b1 << i);

        // Pack L1 -> CPU outputs
        assign cpu_ready[i] = l1_cpu_ready[i];
        assign cpu_resp_valid[i] = l1_cpu_resp_valid[i];
        assign cpu_data[i*(8*CACHE_LINE_SIZE) +: (8*CACHE_LINE_SIZE)] = l1_cpu_data[i];
    end
endgenerate

// ================ Internal Wires between L1 and Directory Controller ================
// L1 -> DC (these are per core)
wire l1_dc_signal [NUM_CORES-1:0];
wire [NUM_CORES-1:0] l1_dc_core_o [NUM_CORES-1:0];
wire [ADDR_WIDTH-1:0] l1_dc_addr_o [NUM_CORES-1:0];
wire [2:0] l1_dc_coh_req_o [NUM_CORES-1:0];
wire [(8*CACHE_LINE_SIZE)-1:0] l1_dc_l2_data_o [NUM_CORES-1:0];
wire l1_dc_dg_ack [NUM_CORES-1:0];
// DC -> L1 (this is not per core, these are a broadcasted signals)
wire dc_l1_data_signal;
wire [(8*CACHE_LINE_SIZE)-1:0] dc_l1_data;
wire [NUM_CORES-1:0] dc_l1_data_core;
wire [1:0] dc_l1_dg_signal;
wire [NUM_CORES-1:0] dc_l1_dg_core;
wire [ADDR_WIDTH-1:0] dc_l1_dg_addr;

// ================ Arbitered input from multiple L1s to the dc ================
// Simple priority encoder (core 0 prioritized)
wire l1_dc_signal_mux = l1_dc_signal[0] ? l1_dc_signal[0] : l1_dc_signal[1];
wire [NUM_CORES-1:0] l1_dc_core_mux = l1_dc_signal[0] ? l1_dc_core_o[0] : l1_dc_core_o[1];
wire [ADDR_WIDTH-1:0] l1_dc_addr_mux = l1_dc_signal[0] ? l1_dc_addr_o[0] : l1_dc_addr_o[1];
wire [2:0] l1_dc_coh_req_mux = l1_dc_signal[0] ? l1_dc_coh_req_o[0] : l1_dc_coh_req_o[1];
wire [(8*CACHE_LINE_SIZE)-1:0] l1_dc_l2_data_mux = l1_dc_signal[0] ? l1_dc_l2_data_o[0] : l1_dc_l2_data_o[1];
wire l1_dc_dg_ack_mux = l1_dc_dg_ack[0] | l1_dc_dg_ack[1]; // This is driven by owner not requester


// ================ L1 Instances ================
l1 #(.CORE_ID(0), .NUM_CORES(NUM_CORES)) l1_inst0 (
    .clk_i(clk),
    .reset_i(rst),

    // From CPU (gated by core select)
    .cpu_signal_i(cpu_l1_req_valid[0]), // cpu sent down a request (gated)
    .addr_i(cpu_l1_addr[0]),
    .req_i(cpu_l1_req[0]),
    .core_i(cpu_l1_core[0]),

    // From DC (data return; each core checks dc_l1_core)
    .dc_signal_i(dc_l1_data_signal),
    .l1_data_i(dc_l1_data),
    .l1_core_i(dc_l1_data_core),

    // From DC (downgrade/invalidate)
    .dg_signal_i(dc_l1_dg_signal),
    .l1_dg_core_i(dc_l1_dg_core),
    .l1_dg_addr_i(dc_l1_dg_addr),

    // To CPU
    .cpu_ready_o(l1_cpu_ready[0]),
    .cpu_signal_o(l1_cpu_resp_valid[0]),
    .cpu_data_o(l1_cpu_data[0]),

    // To DC
    .dc_signal_o(l1_dc_signal[0]),
    .core_o(l1_dc_core_o[0]), // This is the key used to distinguish the core served!!!
    .addr_o(l1_dc_addr_o[0]),
    .coh_req_o(l1_dc_coh_req_o[0]),
    .l2_data_o(l1_dc_l2_data_o[0]),
    .l1_dg_ack_o(l1_dc_dg_ack[0])
);

l1 #(.CORE_ID(1), .NUM_CORES(NUM_CORES)) l1_inst1 (
    .clk_i(clk),
    .reset_i(rst),

    // From CPU (gated by core select)
    .cpu_signal_i(cpu_l1_req_valid[1]), // cpu sent down a request (gated)
    .addr_i(cpu_l1_addr[1]),
    .req_i(cpu_l1_req[1]),
    .core_i(cpu_l1_core[1]),

    // From DC (data return; each core checks dc_l1_core)
    .dc_signal_i(dc_l1_data_signal),
    .l1_data_i(dc_l1_data),
    .l1_core_i(dc_l1_data_core),

    // From DC (downgrade/invalidate)
    .dg_signal_i(dc_l1_dg_signal),
    .l1_dg_core_i(dc_l1_dg_core),
    .l1_dg_addr_i(dc_l1_dg_addr),

    // To CPU
    .cpu_ready_o(l1_cpu_ready[1]),
    .cpu_signal_o(l1_cpu_resp_valid[1]),
    .cpu_data_o(l1_cpu_data[1]),

    // To DC
    .dc_signal_o(l1_dc_signal[1]),
    .core_o(l1_dc_core_o[1]),
    .addr_o(l1_dc_addr_o[1]),
    .coh_req_o(l1_dc_coh_req_o[1]),
    .l2_data_o(l1_dc_l2_data_o[1]),
    .l1_dg_ack_o(l1_dc_dg_ack[1])
);



directory_controller #(.NUM_CORES(NUM_CORES)) dc(
    .clk_i(clk),
    .reset_i(rst),

    // Input from L1 cache
    .l1_signal_i(l1_dc_signal_mux), // Handshake: L1 is presenting a real coherent request
    .core_i(l1_dc_core_mux), // The core doing the request (one hot)
    .addr_i(l1_dc_addr_mux), // address from coherence request
    .coh_req_i(l1_dc_coh_req_mux),
    .l1_data_i(l1_dc_l2_data_mux), // Complete cache line being written downward to l2 (just data portion)
    .l1_dg_ack_i(l1_dg_ack_mux), // acknowledge that the downgrade has been completed

    // Input from L2
    .l2_signal_i(l2_signal_i), // Handshake: L2 has data ready
    .mem_rdata_i(l2_rdata_i), // Complete cache line returned from lower memory

    // Output to L1 cache
    .l1_signal_o(dc_l1_data_signal), // Handshake: Ready signal for data, meaning controller finished its tasks (I think this is the ACK?)
    .l1_core_o(dc_l1_data_core), // Target core for data
    .l1_data_o(dc_l1_data), // Fetched complete cache line
    .l1_dg_signal_o(dc_l1_dg_signal), // Downgrade signal
    .l1_dg_core_o(dc_l1_dg_core), // Target core for invalidate signal
    .l1_dg_addr_o(dc_l1_dg_addr), // Target address to be downgraded

    // Output to L2
    .l2_req_o(l2_req_o), // Making downward memory request
    .l2_we_o(l2_we_o), // 1 = write req, 0 = read req
    .mem_addr_o(l2_addr_o), // Data address to fetch
    .l2_data_o(l2_wdata_o) // Complete cache line being written downward to l2 (just data portion)
);

endmodule