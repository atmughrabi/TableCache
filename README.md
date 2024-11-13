# TableCache
TableCache is a configurable last-level write-back cache for SRAM-based FPGAs with a number of useful features:
- It is written in portable SystemVerilog, allowing it to be used in both Vivado and Quartus environments.
- It uses a standard AXI interface for input and output requests.
- It is designed for configurability and performance within a compact FPGA resource footprint.
- It supports a parameterizable databank latency for scalability.

## Usage
The top level entity is `l2_cache.sv`, with general configurability facilitated by passed-in parameters.
More minor and niche configuration parameters can be manually tuned by modifying certain local parameters in `replacement_policy.sv`, `l2_databank.sv`, and `l2_cache.sv`.

The `cache_config.sv` file contains one additional configuration option to specify whether AMD (the default), or Intel toolchains are being used. This simply changes the HDL design pattern used to infer FPGA-specific resources, but does not change functionality.

Assertions for error conditions can be disabled by defining ASSERT_OFF in the preprocessor.

An example wrapper suitable for packaging TableCache as a standalone IP in Vivado is provided in `l2_top.sv`.

## Resources
The doc directory contains two images displaying the high-level structure of TableCache. One of these images has been annotated showing the cycle-level behaviour of a read miss that causes an eviction.

For further design details, refer to the paper "TableCache: An Open-Source, Configurable, Last-Level Cache for FPGA Systems" from the FPT 2024 conference.

## Restrictions
As a write-back last-level cache, TableCache supports only the subset of possible AXI transactions that would be reasonably encountered in this context, enabling a faster and smaller implementation. These AXI transaction limitations are as follows:
- Reads and writes must be contained within a single cache line.
- Fixed burst transactions are not supported; incremental and wrapping bursts are.
- The full bus width must be used on the data channels; narrow transactions are not supported.
- Locked transactions are not supported.
- All transactions are treated as write-back read and write allocate.
- The arsnoop signal can be used to indicate CleanInvalid, CleanShared, and MakeInvalid ACE transactions; every other encoding is treated as a regular read.
- The awsnoop signal can be used to indicate a WriteBack transaction (which updates every byte in the cache line); every other encoding is treated as a write that may not update every byte. For performance, WriteBack should be signalled whenever appropriate, as TableCache will then skip the external read request on a write miss.

## License
This project and most of its source files are licensed under the permissive Solderpad Hardware License V2.1, which is a modification to the Apache License V2.0.
The remainder of the files have been slightly modified and taken from the [CVA5](https://github.com/openhwgroup/cva5) project, which is itself licensed under the Apache License V2.0. These files are distinguished by their different header.
