// On the way back up: l1_ready_o, l1_data_o, ACK_o, invalidate_o from the directory need to be routed to the correct L1 instance based on l1_core_o

module top(
    parameter CORE_ID,
    parameter NUM_CORES = 2,
    parameter CORE_ID_BITS = 1,

    parameter CACHE_ENTRIES_PER_CORE = 32, // 32 cache entries per core
    parameter CACHE_LINE_SIZE = 64, // 64 bytes per cache line
    parameter ADDR_WIDTH = 32
)(
    input clk,
    input rst,

    // external CPU inputs
    input wire cpu_signal, // Handshake: a real cpu request is present
    input wire [ADDR_WIDTH-1:0] addr, // address from CPU request
    input wire req, // 0: ld, 1: sd
    input wire [CORE_ID_BITS-1:0] core, // The requesting core

    // external CPU outputs
    output wire cpu_ready, // Handshake: CPU can issue a new request
    output reg cpu_signal, // Handshake: data is ready to be sent to CPU
    output reg [(8*CACHE_LINE_SIZE)-1:0] cpu_data // cache line output to the CPU
)

// ================ Internal Wires ================
// Naming for some of the wires: sender_receiver_wireName
wire dc_l1_data_signal;
wire [(8*CACHE_LINE_SIZE)-1:0] dc_l1_data;
wire [1:0] dg_signal;
wire [CORE_ID_BITS-1:0] dg_core;
wire [ADDR_WIDTH-1:0] dg_addr;



l1 l1_a (
    .CORE_ID(0)
)(
    .clk_i(clk),
    .reset_i(rst),

    // Input from the processor
    cpu_signal_i(cpu_signal), // Handshake: a real cpu request is present
    addr_i(addr), // address from CPU request
    req_i(req), // 0: ld, 1: sd
    core_i(core), // The requesting core

    // Input from the directory controller
    dc_signal_i(dc_l1_data_signal), // Handshake: signaled when data is received from directory controller
    l1_data_i(dc_l1_data), // Fetched cache line
    dg_signal_i(dg_signal), // Invalidate signal
    l1_dg_core_i(dg_core), // Target core for invalidate signal
    l1_dg_addr_i(dg_addr), // Target address to be downgraded

    // Output to the processor
    cpu_ready_o(cpu_ready), // Handshake: CPU can issue a new request
    cpu_signal_o(cpu_signal), // Handshake: data is ready to be sent to CPU
    cpu_data_o(cpu_data), // cache line output to the CPU

    // Output to the directory controller
    output reg dc_signal_o, // Handshake: tells directory a real request is present
    output wire [NUM_CORES-1:0] core_o, // The core doing the request (one hot)
    output wire [ADDR_WIDTH-1:0] addr_o, // address sent down to directory controller
    output reg [2:0] coh_req_o,
    output wire [(8*CACHE_LINE_SIZE)-1:0] l2_data_o, // data to pass to L2 for writeback
    output wire l1_dg_ack_o // acknowledge that the downgrade has been completed
);

directory_controller dc(
    // all parameters default
)(
    .clk_i(clk),
    .reset_i(rst),

    // Input from L1 cache
    input wire l1_signal_i, // Handshake: L1 is presenting a real coherent request
    input wire [NUM_CORES-1:0] core_i, // The core doing the request (one hot)
    input wire [2:0] coh_req_i,
    input wire [ADDR_WIDTH-1:0] addr_i, // address from coherence request
    input wire [(8*CACHE_LINE_SIZE)-1:0] l1_data_i // Complete cache line being written downward to l2 (just data portion)
    input wire l1_dg_ack_i, // acknowledge that the downgrade has been completed

    // Input from L2
    input wire l2_signal_i, // Handshake: L2 has data ready
    input wire [(8*CACHE_LINE_SIZE)-1:0] mem_rdata_i, // Complete cache line returned from lower memory




    // Output to L1 cache
    l1_signal_o(dc_l1_data_signal), // Handshake: Ready signal for data, meaning controller finished its tasks (I think this is the ACK?)
    output reg [CORE_ID_BITS-1:0] l1_core_o, // Target core for data
    l1_data_o(dc_l1_data), // Fetched complete cache line
    l1_dg_signal_o(dg_signal), // Downgrade signal
    l1_dg_core_o(dg_core), // Target core for invalidate signal
    l1_dg_addr_o(dg_addr), // Target address to be downgraded




    // Output to L2    
    output reg l2_req_o, // Making downward memory request
    output reg l2_we_o, // 1 = write req, 0 = read req
    output reg [ADDR_WIDTH-1:0] mem_addr_o, // Data address to fetch
    output wire [(8*CACHE_LINE_SIZE)-1:0] l2_data_o // Complete cache line being written downward to l2 (just data portion)
);






endmodule