// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"


module user_rom #(
    parameter obi_pkg::obi_cfg_t ObiCfg    = obi_pkg::ObiDefaultConfig,
    parameter type               obi_req_t = logic,
    parameter type               obi_rsp_t = logic
) (
    input  logic     clk_i,
    input  logic     rst_ni,
    input  obi_req_t obi_req_i,
    output obi_rsp_t obi_rsp_o
);

    localparam int unsigned NumWords    = 15;
    localparam int unsigned WordIdxBits = $clog2(NumWords);
    localparam logic [31:0] UserRom [NumWords] = '{
        32'h676E_6952, // "Ring"
        32'h696C_5320, // " Sli"
        32'h4D20_6B6E, // "nk M"
        32'h4320_4341, // "AC C"
        32'h2063_6F72, // "roc "
        32'h4D20_7942, // "By M"
        32'h6D69_7861, // "axim"
        32'h6169_6C69, // "ilia"
        32'h6F4B_206E, // "n Ko"
        32'h7265_6863, // "cher"
        32'h4620_2620, // " & F"
        32'h6169_6261, // "abia"
        32'h6541_206E, // "n Ae"
        32'h7472_6567, // "gert"
        32'h0000_7265  // "er"
    };

    // The word index is taken region-relative from the low address bits (the
    // lower 2 bits are the byte offset). The ROM must therefore be mapped at a
    // base aligned to 2**(WordIdxBits+2) bytes (here 64 B) with a region that
    // spans at least NumWords words.
    logic                      req_q;
    logic                      we_q;
    logic [ObiCfg.IdWidth-1:0] id_q;
    logic [WordIdxBits-1:0]    word_idx_q;
    logic is_error;

    `FF(req_q,      obi_req_i.req,                       '0, clk_i, rst_ni)
    `FF(we_q,       obi_req_i.a.we,                      '0, clk_i, rst_ni)
    `FF(id_q,       obi_req_i.a.aid,                     '0, clk_i, rst_ni)
    `FF(word_idx_q, obi_req_i.a.addr[WordIdxBits+2-1:2], '0, clk_i, rst_ni)

    assign is_error = we_q || (word_idx_q >= NumWords);

    always_comb begin
        obi_rsp_o        = '0;
        obi_rsp_o.gnt    = 1'b1;   // always ready to accept a request
        obi_rsp_o.rvalid = req_q;  // one-cycle read latency
        obi_rsp_o.r.rid  = id_q;
        if (is_error) begin
            obi_rsp_o.r.err   = 1'b1;
        end else begin
            obi_rsp_o.r.rdata = UserRom[word_idx_q];
            obi_rsp_o.r.err   = 1'b0;
        end
    end


    `ASSERT_INIT(DataWidthIs32, ObiCfg.DataWidth == 32)

endmodule
