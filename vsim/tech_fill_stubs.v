// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Simulation stubs for physical-only cells of the ez130_8t standard-cell
// library. These cells (fillers, well taps, antenna diodes) carry no logic
// function and are therefore omitted from the functional model ez130_8t.v,
// but they ARE instantiated in the place-and-route netlist (openroad/out/croc.v).
// Without these empty modules, QuestaSim elaboration fails with
// "<cell> is not defined" (e.g. instance FILLER_372_4175).
//
// If any of these triggers a "module already defined" error, it means the
// functional library already provides it -> remove that one stub.

`celldefine
module FILLER1  (); endmodule
module FILLER2  (); endmodule
module FILLER4  (); endmodule
module FILLER8  (); endmodule
module FILLER16 (); endmodule
module WELLTAP  (); endmodule
// Bond pad (the 5l variant instantiated in the netlist); single inout 'pad'.
module bondpad5l_70x70 (inout pad); endmodule
`endcelldefine
