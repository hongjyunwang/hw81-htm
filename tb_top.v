// Drive: cpu_req_valid, cpu_addr, cpu_req, cpu_core, l2_signal_i, l2_rdata_i
// Observe: cpu_ready, cpu_resp_valid, cpu_data, l2_req_o, l2_we_o, l2_addr_o

`timescale 1ns/1ps   // time unit / precision — all # delays are in nanoseconds

module tb_top;

// ================ Parameters ================
localparam NUM_CORES = 2;
localparam CACHE_LINE_SIZE = 64;
localparam ADDR_WIDTH = 32;
localparam CLK_PERIOD = 10; // 10 ns = 100 MHz

// ================ DUT Signals ================
// Rule: inputs to DUT are reg, outputs are wire
reg clk;
reg rst;

// CPU side
reg  [NUM_CORES-1:0] cpu_req_valid;
reg  [NUM_CORES*ADDR_WIDTH-1:0] cpu_addr;
reg  [NUM_CORES-1:0] cpu_req;

wire [NUM_CORES-1:0] cpu_ready;
wire [NUM_CORES-1:0] cpu_resp_valid;
wire [NUM_CORES*(8*CACHE_LINE_SIZE)-1:0] cpu_data;

// L2 side
reg l2_signal_i;
reg [(8*CACHE_LINE_SIZE)-1:0] l2_rdata_i;

wire l2_req_o;
wire l2_we_o;
wire [ADDR_WIDTH-1:0] l2_addr_o;
wire [(8*CACHE_LINE_SIZE)-1:0] l2_wdata_o;

// ================ DUT Instantiation (top module) ================
top #(
    .NUM_CORES(NUM_CORES),
    .CACHE_LINE_SIZE(CACHE_LINE_SIZE),
    .ADDR_WIDTH(ADDR_WIDTH)
) dut (
    .clk(clk),
    .rst(rst),
    
    .cpu_req_valid(cpu_req_valid),
    .cpu_addr(cpu_addr),
    .cpu_req(cpu_req),
    .cpu_ready(cpu_ready),
    .cpu_resp_valid(cpu_resp_valid),
    .cpu_data(cpu_data),

    .l2_signal_i(l2_signal_i),
    .l2_rdata_i(l2_rdata_i),
    .l2_req_o(l2_req_o),
    .l2_we_o(l2_we_o),
    .l2_addr_o(l2_addr_o),
    .l2_wdata_o(l2_wdata_o)
);

// ================ Clock Generation ================
// Runs forever
initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

// ================ Waveform Dump ================
// Creates a .vcd file you can open in GTKWave
// initial begin
//     $dumpfile("tb_top.vcd");
//     $dumpvars(0, tb_top); // 0 = dump all levels under tb_top
// end

// ================ Helper Tasks ================
// Tasks let you name common sequences so stimulus blocks stay readable

// Wait N rising edges
task wait_cycles;
    input integer n;
    integer k;
    begin
        for (k = 0; k < n; k = k + 1)
            @(posedge clk);
    end
endtask

// Apply reset
task apply_reset;
    begin
        rst = 1;
        cpu_req_valid = 0;
        l2_signal_i = 0;
        wait_cycles(4);
        @(negedge clk); // deassert on a negedge so it's stable by next posedge
        rst = 0;
        $display("[%0t] Reset released", $time);
    end
endtask

// Issue a CPU load request from a specific core
task cpu_load;
    input [NUM_CORES-1:0] issuing_core;
    input [ADDR_WIDTH-1:0] address;
    begin
        @(negedge clk);
        cpu_addr[issuing_core*ADDR_WIDTH +: ADDR_WIDTH] = address;
        cpu_req[issuing_core] = 0;
        cpu_req_valid[issuing_core] = 1;
        $display("[%0t] LOAD  core=%0d addr=0x%08h", $time, issuing_core, address);
        @(posedge clk);
        @(negedge clk);
        cpu_req_valid[issuing_core] = 0;
    end
endtask

// Issue a CPU store request from a specific core
task cpu_store;
    input [NUM_CORES-1:0] issuing_core;
    input [ADDR_WIDTH-1:0] address;
    begin
        @(negedge clk);
        cpu_addr[issuing_core*ADDR_WIDTH +: ADDR_WIDTH] = address;
        cpu_req[issuing_core] = 1;
        cpu_req_valid[issuing_core] = 1;
        $display("[%0t] STORE core=%0d addr=0x%08h", $time, issuing_core, address);
        @(posedge clk);
        @(negedge clk);
        cpu_req_valid[issuing_core] = 0;
    end
endtask

// Simulate L2 returning a cache line after the DC requests it
// Call this after you see l2_req_o go high
task l2_respond;
    input [(8*CACHE_LINE_SIZE)-1:0] data;
    input integer latency_cycles; // model L2 latency
    begin
        wait_cycles(latency_cycles);
        @(negedge clk);
        l2_rdata_i = data;
        l2_signal_i = 1;
        @(posedge clk);
        @(negedge clk);
        l2_signal_i = 0;
        $display("[%0t] Test Bench: L2 responded with data", $time);
    end
endtask

// Block until cpu_resp_valid goes high (or timeout)
task wait_for_cpu_resp;
    input integer timeout_cycles;
    integer t;
    begin
        t = 0;
        while (!cpu_resp_valid && t < timeout_cycles) begin
            @(posedge clk);
            t = t + 1;
        end
        if (t >= timeout_cycles)
            $display("[%0t] TIMEOUT waiting for cpu_resp_valid", $time);
        else
            $display("[%0t] CPU response received: data=0x%h", $time, cpu_data);
    end
endtask






// ================ Test Cases ================
initial begin
    apply_reset;
    wait_cycles(2);

    // // ---------- Test 1: Simple load, cold miss ----------
    // $display("\n=== TEST 1: Cold miss load, core 0 ===");
    // fork
    //     // Thread A: issue the CPU request
    //     begin
    //         cpu_load(0, 32'hDEAD_0000);
    //     end

    //     // Thread B: wait for the DC to reach L2, then respond
    //     // (fork lets A and B run concurrently, join waits for both)
    //     begin
    //         @(posedge l2_req_o); // wait until DC asks L2
    //         $display("[%0t] DC issued L2 read for addr=0x%08h", $time, l2_addr_o);
    //         l2_respond(512'hCAFE_BABE, 10);
    //     end
    // join

    // wait_for_cpu_resp(50);
    // wait_cycles(2);


    // // ---------- Test 2: Load same line (should hit) ----------
    // $display("\n=== TEST 2: Load same line (should hit) ===");
    // cpu_load(0, 32'hDEAD_0000);
    // wait_for_cpu_resp(50);
    // wait_cycles(2);


    // ---------- Test 3: Store miss (cold miss, new address) ----------
    $display("\n=== TEST 3: Store miss, core 0 ===");
    fork
        begin
            cpu_store(0, 32'hBEEF_0000); // store for core 0, address 32'hBEEF_0000
        end
        begin
            @(posedge l2_req_o);
            $display("[%0t] DC issued L2 read for addr=0x%08h", $time, l2_addr_o);
            l2_respond(512'hDEAD_BEEF, 10);
        end
    join

    wait_for_cpu_resp(50);
    wait_cycles(2);

    // ---------- Test 4: Store same line (should hit, line is in M) ----------
    $display("\n=== TEST 4: Store same line (should hit) ===");
    cpu_store(0, 32'hBEEF_0000);
    wait_for_cpu_resp(10);
    wait_cycles(2);

    // // ---------- Test 5: Load miss, no owner ----------
    // // Fresh address, DC goes straight to L2
    // $display("\n=== TEST 5: Load miss, no owner ===");
    // fork
    //     begin
    //         cpu_load(0, 32'hAAAA_0000);
    //     end
    //     begin
    //         @(posedge l2_req_o);
    //         $display("[%0t] No-owner path: DC fetching from L2", $time);
    //         l2_respond(512'hAAAA_AAAA, 10);
    //     end
    // join
    // wait_for_cpu_resp(50);
    // wait_cycles(2);

    // ---------- Test 6: Load miss, with owner ----------
    // Give core 1 an M-state line on 0xCAFE_0000 (core 1 is an owner)
    // Done by making it store to the line 
    // $display("\n=== TEST 6 setup: Core 1 acquires M-state line ===");
    // fork
    //     begin
    //         cpu_store(1, 32'hCAFE_0000);
    //     end
    //     begin
    //         @(posedge l2_req_o);
    //         $display("[%0t] Core 1 store miss: DC fetching from L2", $time);
    //         l2_respond(512'hCAFE_CAFE, 10);
    //     end        
    // join
    // wait_for_cpu_resp(50);
    // wait_cycles(4);

    // Step 2: core 0 loads the same line — core 1 is the M-state owner
    // DC should: downgrade core 1 (M→S), core 1 writes back and forwards
    // data to core 0. No l2_respond needed — data comes from core 1, not L2.
    // However, core 1's writeback may pulse l2_we_o=1 (a write, no response needed).
    // $display("\n=== TEST 6: Load miss, core 1 is owner ===");
    // cpu_load(0, 32'hCAFE_0000);
    // wait_for_cpu_resp(50);
    // wait_cycles(2);

    

    end

// ================ Optional Continuous Monitor ================
// $monitor fires automatically whenever a listed signal changes
// initial begin
//     $monitor("[%0t] l2_req=%b l2_we=%b l2_addr=0x%08h cpu_resp=%b", $time, l2_req_o, l2_we_o, l2_addr_o, cpu_resp_valid);
// end

endmodule