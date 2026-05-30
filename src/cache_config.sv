// Copyright 2024 Chris Keilbart
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may
// not use this file except in compliance with the License, or, at your option,
// the Apache License version 2.0. You may obtain a copy of the License at
// https://solderpad.org/licenses/SHL-2.1/. Unless required by applicable law
// or agreed to in writing, any work distributed under the License is
// distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the specific language
// governing permissions and limitations under the License.

package cache_config;

    //Vendor Selection
    typedef enum {
        AMD = 0,
        INTEL = 1
    } vendor_config_t;
    localparam vendor_config_t FPGA_VENDOR = AMD;

    //Replacement Policies
    typedef enum {
        LRU,
        FRQ,
        SECOND_CHANCE,
        RANDOM,
        SRRIP, //Equivalent to NRU when RRPV_WIDTH = 1
        GRASP
    } replacement_policy_t;

    //AXI typedefs
    //These would normally be in a separate file but Quartus can't handle that
    typedef struct packed {
        logic[31:0] araddr;
        logic[7:0] arlen;
        logic[2:0] arsize;
        logic[1:0] arburst;
        logic arlock;
        logic[3:0] arcache;
        logic[2:0] arprot;
        logic[3:0] arqos;
        logic[3:0] arregion;
        logic arvalid;
        logic[3:0] arsnoop; //ACE only
    } ar_t;

    typedef struct packed {
        logic rvalid;
        logic rlast;
        logic[3:0] rresp; //3:2 for ACE only
    } r_t;

    typedef struct packed {
        logic[31:0] awaddr;
        logic[7:0] awlen;
        logic[2:0] awsize;
        logic[1:0] awburst;
        logic awlock;
        logic[3:0] awcache;
        logic[2:0] awprot;
        logic[3:0] awqos;
        logic[3:0] awregion;
        logic[2:0] awsnoop;
        logic awvalid;
    } aw_t;

    typedef struct packed {
        logic wlast;
        logic wvalid;
    } w_t;

    typedef struct packed {
        logic[1:0] bresp;
        logic bvalid;
    } b_t;

endpackage
