`ifndef SLINK_OBI_TYPEDEF_SVH
`define SLINK_OBI_TYPEDEF_SVH


`define SLINK_OBI_TYPEDEF_DEFAULT_A_CHAN_T(a_chan_read_t, a_chan_write_t, ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, NODE_ID_WIDTH)  \
  typedef struct packed {                                                                                                   \
    logic [  ADDR_WIDTH-NODE_ID_WIDTH-1:0] addr;                                                                            \
    logic [DATA_WIDTH/8-1:0] be;                                                                                            \
    logic [  DATA_WIDTH-1:0] wdata;                                                                                         \
    logic [    ID_WIDTH-1:0] aid;                                                                                           \
  } a_chan_write_t;                                                                                                         \
                                                                                                                            \
  typedef struct packed {                                                                                                   \
    logic [  ADDR_WIDTH-NODE_ID_WIDTH-1:0] addr;                                                                            \
    logic [DATA_WIDTH/8-1:0] be;                                                                                            \
    logic [    ID_WIDTH-1:0] aid;                                                                                           \
  } a_chan_read_t;                                                                                                                             
  
`define SLINK_OBI_TYPEDEF_DEFAULT_R_CHAN_T(r_chan_read_t, r_chan_write_t, RDATA_WIDTH, ID_WIDTH)  \
  typedef struct packed {                                                                         \
    logic [   ID_WIDTH-1:0] rid;                                                                  \
    logic                   err;                                                                  \
  } r_chan_write_t;                                                                               \
                                                                                                  \
  typedef struct packed {                                                                         \
    logic [RDATA_WIDTH-1:0] rdata;                                                                \
    logic [   ID_WIDTH-1:0] rid;                                                                  \
    logic                   err;                                                                  \
  } r_chan_read_t;

`define SLINK_OBI_TYPEDEF_NOBE_A_CHAN_T(a_chan_read_t, a_chan_write_t, ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, NODE_ID_WIDTH)     \
  typedef struct packed {                                                                                                   \
    logic [  ADDR_WIDTH-NODE_ID_WIDTH-1:0] addr;                                                                            \
    logic [  DATA_WIDTH-1:0] wdata;                                                                                         \
    logic [    ID_WIDTH-1:0] aid;                                                                                           \
  } a_chan_write_t;                                                                                                         \
                                                                                                                            \
  typedef struct packed {                                                                                                   \
    logic [  ADDR_WIDTH-NODE_ID_WIDTH-1:0] addr;                                                                            \
    logic [    ID_WIDTH-1:0] aid;                                                                                           \
  } a_chan_read_t;                                                                                                                             
  
`define SLINK_OBI_TYPEDEF_NOBE_OPTIONAL_A_CHAN_T(a_chan_read_t, a_chan_write_t, ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, NODE_ID_WIDTH ,a_optional_t)  \
  typedef struct packed {                                                                                                                       \
    logic [  ADDR_WIDTH-NODE_ID_WIDTH-1:0] addr;                                                                                                \
    logic [  DATA_WIDTH-1:0] wdata;                                                                                                             \
    logic [    ID_WIDTH-1:0] aid;                                                                                                               \
    a_optional_t             a_optional;                                                                                                        \
  } a_chan_write_t;                                                                                                                             \
                                                                                                                                                \
  typedef struct packed {                                                                                                                       \
    logic [  ADDR_WIDTH-NODE_ID_WIDTH-1:0] addr;                                                                                                \
    logic [    ID_WIDTH-1:0] aid;                                                                                                               \
    a_optional_t             a_optional;                                                                                                        \
  } a_chan_read_t;   

`define SLINK_OBI_TYPEDEF_ALL_A_CHAN_T(a_chan_read_t, a_chan_write_t, ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, NODE_ID_WIDTH, a_optional_t)  \
  typedef struct packed {                                                                                                             \
    logic [  ADDR_WIDTH-NODE_ID_WIDTH-1:0] addr;                                                                                      \
    logic [DATA_WIDTH/8-1:0] be;                                                                                                      \
    logic [  DATA_WIDTH-1:0] wdata;                                                                                                   \
    logic [    ID_WIDTH-1:0] aid;                                                                                                     \
    a_optional_t             a_optional;                                                                                              \
  } a_chan_write_t;                                                                                                                   \
                                                                                                                                      \
  typedef struct packed {                                                                                                             \
    logic [  ADDR_WIDTH-NODE_ID_WIDTH-1:0] addr;                                                                                      \
    logic [DATA_WIDTH/8-1:0] be;                                                                                                      \
    logic [    ID_WIDTH-1:0] aid;                                                                                                     \
    a_optional_t             a_optional;                                                                                              \
  } a_chan_read_t;   

`define SLINK_OBI_TYPEDEF_ALL_R_CHAN_T(r_chan_read_t, r_chan_write_t, RDATA_WIDTH, ID_WIDTH, r_optional_t)    \
  typedef struct packed {                                                                                     \
    logic [RDATA_WIDTH-1:0] rdata;                                                                            \
    logic [   ID_WIDTH-1:0] rid;                                                                              \
    logic                   err;                                                                              \
    r_optional_t            r_optional;                                                                       \
  } r_chan_read_t;                                                                                            \
                                                                                                              \
  typedef struct packed {                                                                                     \
    logic [   ID_WIDTH-1:0] rid;                                                                              \
    logic                   err;                                                                              \
    r_optional_t            r_optional;                                                                       \
  } r_chan_write_t;



`define SLINK_OBI_TYPEDEF_ALL(slink_obi_t, cfg, a_optional_t, r_optional_t)                                                                            \
  `SLINK_OBI_TYPEDEF_ALL_A_CHAN_T(slink_obi_t``_a_chan_read_t, slink_obi_t``_a_chan_write_t, cfg.AddrWidth, cfg.DataWidth, cfg.IDWidth, cfg.NodeIDWidth, a_optional_t)  \
  `SLINK_OBI_TYPEDEF_ALL_R_CHAN_T(slink_obi_t``_r_chan_read_t, slink_obi_t``_r_chan_write_t, cfg.DataWidth, cfg.IDWidth, r_optional_t)                 

`define SLINK_OBI_TYPEDEF_DEFAULT(slink_obi_t, cfg)                                                                                          \
  `SLINK_OBI_TYPEDEF_DEFAULT_A_CHAN_T(slink_obi_t``_a_chan_read_t, slink_obi_t``_a_chan_write_t, cfg.AddrWidth, cfg.DataWidth, cfg.IDWidth, cfg.NodeIDWidth)  \
  `SLINK_OBI_TYPEDEF_DEFAULT_R_CHAN_T(slink_obi_t``_r_chan_read_t, slink_obi_t``_r_chan_write_t, cfg.DataWidth, cfg.IDWidth)                  

`define SLINK_OBI_TYPEDEF_NOBE(slink_obi_t, cfg)                                                                                          \
  `SLINK_OBI_TYPEDEF_NOBE_A_CHAN_T(slink_obi_t``_a_chan_read_t, slink_obi_t``_a_chan_write_t, cfg.AddrWidth, cfg.DataWidth, cfg.IDWidth, cfg.NodeIDWidth)  \
  `SLINK_OBI_TYPEDEF_DEFAULT_R_CHAN_T(slink_obi_t``_r_chan_read_t, slink_obi_t``_r_chan_write_t, cfg.DataWidth, cfg.IDWidth)              

`define SLINK_OBI_TYPEDEF_NOBE_OPTIONAL(slink_obi_t, cfg, a_optional_t, r_optional_t)                                                                            \
  `SLINK_OBI_TYPEDEF_NOBE_OPTIONAL_A_CHAN_T(slink_obi_t``_a_chan_read_t, slink_obi_t``_a_chan_write_t, cfg.AddrWidth, cfg.DataWidth, cfg.IDWidth, cfg.NodeIDWidth, a_optional_t)  \
  `SLINK_OBI_TYPEDEF_ALL_R_CHAN_T(slink_obi_t``_r_chan_read_t, slink_obi_t``_r_chan_write_t, cfg.DataWidth, cfg.IDWidth, r_optional_t)                           

`endif // SLINK_OBI_TYPEDEF_SVH
