// On the way back up: l1_ready_o, l1_data_o, ACK_o, invalidate_o from the directory need to be routed to the correct L1 instance based on l1_core_o

module top #(
    parameter NUM_CORES = 2,
    parameter CORE_ID_BITS = 1,

    parameter CACHE_ENTRIES_PER_CORE = 32, // 32 cache entries per core
    parameter CACHE_LINE_SIZE = 64, // 64 bytes per cache line
    parameter ADDR_WIDTH = 32
)(
    input clk,
    input rst,

    // CPU-facing ports
    input wire cpu_req_valid, // renamed: was cpu_signal (collision)
    input wire [ADDR_WIDTH-1:0] cpu_addr,
    input wire cpu_req, // 0=ld, 1=sd
    input wire [CORE_ID_BITS-1:0] cpu_core,

    output wire cpu_ready,
    output wire cpu_resp_valid, // renamed: was cpu_signal
    output wire [(8*CACHE_LINE_SIZE)-1:0] cpu_data,

    // L2-facing ports
    input wire l2_signal_i,
    input wire [(8*CACHE_LINE_SIZE)-1:0] l2_rdata_i,

    output wire l2_req_o,
    output wire l2_we_o,
    output wire [ADDR_WIDTH-1:0] l2_addr_o,
    output wire [(8*CACHE_LINE_SIZE)-1:0] l2_wdata_o
)

// ================ Internal Wires ================
// Naming for some of the wires: sender_receiver_wireName
wire dc_l1_data_signal;
wire [(8*CACHE_LINE_SIZE)-1:0] dc_l1_data;
wire [CORE_ID_BITS-1:0] dc_l1_data_core;
wire [1:0] dg_signal;
wire [CORE_ID_BITS-1:0] dg_core;
wire [ADDR_WIDTH-1:0] dg_addr;

wire l1_dc_dignal;
wire [NUM_CORES-1:0] l1_dc_core; // The core doing the request (one hot)
wire [ADDR_WIDTH-1:0] l1_dc_addr; // address sent down to directory controller
wire [2:0] l1_dc_coh_req;
wire [(8*CACHE_LINE_SIZE)-1:0] l1_dc_l2_data; // data to pass to L2 for writeback
wire l1_dg_ack; // acknowledge that the downgrade has been completed


// ================ Output Mux (core -> CPU) ================
// Route the responding core's outputs back to the CPU
assign cpu_ready = cpu_ready_per_core[cpu_core];
assign cpu_resp_valid = cpu_resp_valid_per_core[cpu_core];
assign cpu_data = cpu_data_per_core[cpu_core];


// ================ L1 Instances ================
genvar i;
generate
    for (i = 0; i < NUM_CORES; i = i + 1) begin : l1_gen
        l1 #(.CORE_ID(i)) l1_inst (
            .clk_i(clk),
            .reset_i(rst),

            // From CPU (gated by core select)
            .cpu_signal_i(cpu_req_valid && (cpu_core == i)),
            .addr_i(cpu_addr),
            .req_i(cpu_req),
            .core_i(cpu_core),

            // From DC (data return; each core checks dc_l1_core)
            .dc_signal_i(dc_l1_signal),
            .l1_core_i(dc_l1_core),
            .l1_data_i(dc_l1_data),

            // From DC (downgrade/invalidate)
            .dg_signal_i(dg_signal),
            .l1_dg_core_i(dg_core),
            .l1_dg_addr_i(dg_addr),

            // To CPU
            .cpu_ready_o(cpu_ready_per_core[i]),
            .cpu_signal_o(cpu_resp_valid_per_core[i]),
            .cpu_data_o(cpu_data_per_core[i]),

            // To DC (arbitrated, only 1 core requests at a time for now)
            .dc_signal_o(l1_dc_signal),
            .core_o(l1_dc_core),
            .addr_o(l1_dc_addr),
            .coh_req_o(l1_dc_coh_req),
            .l2_data_o(l1_dc_wdata),
            .l1_dg_ack_o(l1_dg_ack)
        );
    end
endgenerate



directory_controller dc(
    .clk_i(clk),
    .reset_i(rst),

    // Input from L1 cache
    .l1_signal_i(l1_dc_dignal), // Handshake: L1 is presenting a real coherent request
    .core_i(l1_dc_core), // The core doing the request (one hot)
    .addr_i(l1_dc_addr), // address from coherence request
    .coh_req_i(l1_dc_coh_req),
    .l1_data_i(l1_dc_l2_data), // Complete cache line being written downward to l2 (just data portion)
    .l1_dg_ack_i(l1_dg_ack), // acknowledge that the downgrade has been completed

    // Input from L2
    .l2_signal_i(l2_signal_i), // Handshake: L2 has data ready
    .mem_rdata_i(l2_rdata_i), // Complete cache line returned from lower memory

    // Output to L1 cache
    .l1_signal_o(dc_l1_data_signal), // Handshake: Ready signal for data, meaning controller finished its tasks (I think this is the ACK?)
    .l1_core_o(dc_l1_data_core), // Target core for data
    .l1_data_o(dc_l1_data), // Fetched complete cache line
    .l1_dg_signal_o(dg_signal), // Downgrade signal
    .l1_dg_core_o(dg_core), // Target core for invalidate signal
    .l1_dg_addr_o(dg_addr), // Target address to be downgraded

    // Output to L2
    .l2_req_o(l2_req_o), // Making downward memory request
    .l2_we_o(l2_we_o), // 1 = write req, 0 = read req
    .mem_addr_o(l2_addr_o), // Data address to fetch
    .l2_data_o(l2_wdata_o) // Complete cache line being written downward to l2 (just data portion)
);






endmodule