"""l2_top AXI ID-width and namespace mapping regression."""
from __future__ import annotations

import os

import cocotb
from cocotb.triggers import Event, ReadOnly, RisingEdge

from tb_common import BASE, attach_master, attach_mem, golden, reset_dut

ID_W = int(os.environ.get("TC_ID_W", "4"))
M_ID_W = int(os.environ.get("TC_M_ID_W") or str(ID_W + 1))
NUM_IDS = 1 << ID_W
BLOCK_BYTES = 4
LINE_W = int(os.environ.get("TC_LINE_W", "8"))
LINES = int(os.environ.get("TC_LINES", "64"))
LINE_BYTES = LINE_W * BLOCK_BYTES
WB_ALLOC = 0xF


@cocotb.test()
async def test_l2top_id_namespace(dut):
    await reset_dut(dut)
    assert len(dut.s_arid) == ID_W and len(dut.m_arid) == M_ID_W
    attach_mem(dut, size_bytes=1 << 22)
    master = attach_master(dut)

    mem_read_ids = []
    slave_read_ids = []
    slave_write_ids = []

    async def monitor_ids():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.m_arvalid) and int(dut.m_arready):
                mem_read_ids.append(int(dut.m_arid))
            if int(dut.s_rvalid) and int(dut.s_rready) and int(dut.s_rlast):
                slave_read_ids.append(int(dut.s_rid))
            if int(dut.s_bvalid) and int(dut.s_bready):
                slave_write_ids.append(int(dut.s_bid))

    monitor = cocotb.start_soon(monitor_ids())

    # Cold reads: memory IDs must be {1'b1, slave_id}.
    read_events = []
    read_addrs = []
    for slave_id in range(NUM_IDS):
        addr = BASE + (slave_id + 1) * LINE_BYTES
        event = Event()
        master.init_read(
            addr, BLOCK_BYTES, arid=slave_id, cache=WB_ALLOC, event=event)
        read_events.append(event)
        read_addrs.append(addr)
    for addr, event in zip(read_addrs, read_events):
        await event.wait()
        assert int.from_bytes(event.data.data, "little") == golden(addr)

    assert sorted(mem_read_ids[:NUM_IDS]) == [
        (1 << ID_W) | slave_id for slave_id in range(NUM_IDS)
    ], f"read ID expansion wrong: {mem_read_ids}"
    assert sorted(slave_read_ids[:NUM_IDS]) == list(range(NUM_IDS))

    # Cold partial writes use the RMW read-fill path: those memory AR IDs must
    # be {1'b0, slave_id}, complementing the {1'b1, slave_id} demand-read IDs.
    read_fill_count = len(mem_read_ids)
    write_events = []
    for slave_id in range(NUM_IDS):
        addr = BASE + (NUM_IDS + slave_id + 8) * LINE_BYTES
        value = 0xD000_0000 | slave_id
        event = Event()
        master.init_write(
            addr, value.to_bytes(BLOCK_BYTES, "little"),
            awid=slave_id, cache=WB_ALLOC, event=event)
        write_events.append(event)
    for event in write_events:
        await event.wait()

    for _ in range(10_000):
        await RisingEdge(dut.clk)
        if len(mem_read_ids) >= read_fill_count + NUM_IDS:
            break
    monitor.kill()
    write_fill_ids = mem_read_ids[read_fill_count:read_fill_count + NUM_IDS]
    assert sorted(write_fill_ids) == list(range(NUM_IDS)), (
        f"write-RMW ID expansion wrong: {write_fill_ids}; all mem ARs={mem_read_ids}")
    assert sorted(slave_write_ids[:NUM_IDS]) == list(range(NUM_IDS))
    dut._log.info(
        f"[l2top-ids] S_ID_W={ID_W} M_ID_W={M_ID_W}: all {NUM_IDS} "
        "read/write IDs mapped and returned correctly")
