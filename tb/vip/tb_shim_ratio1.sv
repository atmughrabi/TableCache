// Self-checking xsim TB for the tc_narrow_shim RATIO=1 (BLOCK_W==NARROW_W) offset
// bug: an odd 4-byte-offset read must NOT return X, and an odd-offset write must
// place data on the (single) 32-bit lane. Verilator masks the out-of-range slice,
// so this must run under xsim (4-state) to be meaningful.
module tb_shim_ratio1;
    // Overridable via xelab -generic_top so the RATIO=1 slice bug is proven at
    // multiple widths (BLOCK_W==NARROW_W). "odd word" generalizes: the offset the
    // buggy capture leaked is address bit $clog2(NARROW_B), so consecutive narrow
    // words (NARROW_B apart) alternate the leaked bit.
    parameter int NARROW_W = 32;
    parameter int BLOCK_W  = 32;   // RATIO = 1 (must equal NARROW_W)
    localparam int ID_W     = 4;
    localparam int NB       = NARROW_W/8;   // narrow bytes; leaked bit = $clog2(NB)

    // NARROW_W-wide, address-dependent data so a mis-slice shows up as X/mismatch.
    function automatic logic [NARROW_W-1:0] genw(input logic [31:0] a);
        genw = {(NARROW_W/32){a | 32'hCAFE_0000}};
    endfunction
    localparam int ADDR_W   = 32;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    // s (narrow) side
    logic [ADDR_W-1:0] s_araddr; logic [7:0] s_arlen; logic [2:0] s_arsize;
    logic [1:0] s_arburst; logic [3:0] s_arsnoop; logic [ID_W-1:0] s_arid;
    logic s_arvalid; logic s_arready;
    logic [NARROW_W-1:0] s_rdata; logic [1:0] s_rresp; logic s_rlast;
    logic [ID_W-1:0] s_rid; logic s_rvalid; logic s_rready;
    logic [ADDR_W-1:0] s_awaddr; logic [7:0] s_awlen; logic [2:0] s_awsize;
    logic [1:0] s_awburst; logic [2:0] s_awsnoop; logic [ID_W-1:0] s_awid;
    logic s_awvalid; logic s_awready;
    logic [NARROW_W-1:0] s_wdata; logic [NARROW_W/8-1:0] s_wstrb; logic s_wlast;
    logic s_wvalid; logic s_wready;
    logic [1:0] s_bresp; logic [ID_W-1:0] s_bid; logic s_bvalid; logic s_bready;
    // m (wide) side
    logic [ADDR_W-1:0] m_araddr; logic [7:0] m_arlen; logic [2:0] m_arsize;
    logic [1:0] m_arburst; logic [3:0] m_arsnoop; logic [ID_W-1:0] m_arid;
    logic m_arvalid; logic m_arready;
    logic [BLOCK_W-1:0] m_rdata; logic [1:0] m_rresp; logic m_rlast;
    logic [ID_W-1:0] m_rid; logic m_rvalid; logic m_rready;
    logic [ADDR_W-1:0] m_awaddr; logic [7:0] m_awlen; logic [2:0] m_awsize;
    logic [1:0] m_awburst; logic [2:0] m_awsnoop; logic [ID_W-1:0] m_awid;
    logic m_awvalid; logic m_awready;
    logic [BLOCK_W-1:0] m_wdata; logic [BLOCK_W/8-1:0] m_wstrb; logic m_wlast;
    logic m_wvalid; logic m_wready;
    logic [1:0] m_bresp; logic [ID_W-1:0] m_bid; logic m_bvalid; logic m_bready;

    tc_narrow_shim #(
        .NARROW_W(NARROW_W), .BLOCK_W(BLOCK_W), .ID_W(ID_W), .ADDR_W(ADDR_W),
        .MAX_OUTSTANDING_W(16), .ENABLE_LINE_BUFFER(1'b1),
        .PROMOTE_WMISS_TO_RW(1'b0), .READ_REORDER_DEPTH(1)
    ) dut (.*);

    int errors = 0;

    task automatic do_read(input [ADDR_W-1:0] addr, input [BLOCK_W-1:0] mem_word);
        // Issue one narrow read; respond on the wide side with mem_word; check s_rdata.
        // s_arready is gated on m_arready (miss-accept fires the wide AR), so keep
        // m_arready high up front.
        @(posedge clk);
        m_arready <= 1'b1; s_rready <= 1'b1;
        s_araddr <= addr; s_arid <= '0; s_arlen <= 8'd0; s_arsize <= 3'($clog2(NB));
        s_arburst <= 2'b01; s_arsnoop <= '0; s_arvalid <= 1'b1;
        // wait AR accept
        do @(posedge clk); while (!s_arready);
        s_arvalid <= 1'b0;
        // provide the wide R beat (the wide AR fired the same cycle as s_arready).
        // The shim forwards R COMBINATIONALLY (s_rvalid tracks m_rvalid), so hold
        // m_rvalid and capture s_rdata in the same cycle the response handshakes.
        m_rdata  <= mem_word; m_rid <= '0; m_rresp <= '0; m_rlast <= 1'b1;
        m_rvalid <= 1'b1;
        forever begin
            @(posedge clk);
            if (m_rvalid && m_rready && s_rvalid && s_rready) begin
                if ($isunknown(s_rdata) || s_rdata !== mem_word) begin
                    $display("  FAIL read 0x%08x: s_rdata=%h exp=%h %s", addr,
                             s_rdata, mem_word, $isunknown(s_rdata) ? "(X)" : "");
                    errors++;
                end else
                    $display("  ok   read 0x%08x -> %h %s", addr, s_rdata,
                             (addr & 4) ? "ODD" : "even");
                break;
            end
        end
        m_rvalid <= 1'b0;
        @(posedge clk);
    endtask

    task automatic do_write(input [ADDR_W-1:0] addr, input [NARROW_W-1:0] wd);
        // Issue one narrow write; capture the wide lane the shim drives; check it.
        @(posedge clk);
        m_wready <= 1'b1; m_awready <= 1'b1; s_bready <= 1'b1;
        s_awaddr <= addr; s_awid <= '0; s_awlen <= 8'd0; s_awsize <= 3'($clog2(NB));
        s_awburst <= 2'b01; s_awsnoop <= 3'b101; s_awvalid <= 1'b1;
        do @(posedge clk); while (!s_awready);
        s_awvalid <= 1'b0;
        s_wdata <= wd; s_wstrb <= '1; s_wlast <= 1'b1; s_wvalid <= 1'b1;
        do @(posedge clk); while (!(m_wvalid && m_wready));
        if ($isunknown(m_wdata[NARROW_W-1:0]) || m_wdata[NARROW_W-1:0] !== wd) begin
            $display("  FAIL write 0x%08x: m_wdata[31:0]=%h exp=%h %s", addr,
                     m_wdata[NARROW_W-1:0], wd,
                     $isunknown(m_wdata[NARROW_W-1:0]) ? "(X)" : "");
            errors++;
        end else
            $display("  ok   write 0x%08x -> m_wdata[31:0]=%h %s", addr,
                     m_wdata[NARROW_W-1:0], (addr & 4) ? "ODD" : "even");
        s_wvalid <= 1'b0;
        // drain B
        m_bvalid <= 1'b1; m_bresp <= '0; m_bid <= '0;
        do @(posedge clk); while (!s_bvalid);
        m_bvalid <= 1'b0;
        @(posedge clk);
    endtask

    initial begin
        // idle
        s_arvalid=0; s_rready=0; s_awvalid=0; s_wvalid=0; s_bready=0;
        m_arready=0; m_rvalid=0; m_awready=0; m_wready=0; m_bvalid=0;
        s_araddr=0; s_arlen=0; s_arsize=0; s_arburst=0; s_arsnoop=0; s_arid=0;
        s_awaddr=0; s_awlen=0; s_awsize=0; s_awburst=0; s_awsnoop=0; s_awid=0;
        s_wdata=0; s_wstrb=0; s_wlast=0;
        m_rdata=0; m_rresp=0; m_rlast=0; m_rid=0; m_bresp=0; m_bid=0;
        repeat (8) @(posedge clk);
        rst <= 1'b0;
        repeat (4) @(posedge clk);

        // Consecutive narrow words must all select the sole RATIO=1 lane.
        for (int k = 0; k < 4; k++)
            do_read(32'h8000_1000 + k*NB, genw(32'h8000_1000 + k*NB));

        // WRITES: odd-offset write must still land on the single NARROW_W lane.
        for (int k = 0; k < 4; k++)
            do_write(32'h8000_2000 + k*NB, genw(32'h8000_2000 + k*NB));

        if (errors == 0) $display("TB_SHIM_RATIO1: PASS");
        else             $display("TB_SHIM_RATIO1: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("TB_SHIM_RATIO1: TIMEOUT");
        $finish;
    end
endmodule
