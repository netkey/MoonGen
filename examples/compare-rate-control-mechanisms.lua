--- This script can be used to determine if a device is affected by the corrupted packets
--  that are generated by the software rate control method.
--  It generates CBR traffic via both methods and compares the resulting latency distributions.
--  TODO: this module should also test L3 traffic (but not just L3 due to size constraints (timestamping limitations))
local dpdk		= require "dpdk"
local memory	= require "memory"
local ts		= require "timestamping"
local device	= require "device"
local filter	= require "filter"
local timer		= require "timer"
local stats		= require "stats"

local REPS = 1
local RUN_TIME = 10
local PKT_SIZE = 60

function master(...)
	local txPort, rxPort, maxRate = tonumberall(...)
	if not txPort or not rxPort then
		errorf("usage: txPort rxPort [maxRate (Mpps)] [steps]")
	end
	local minRate = 0.02
	maxRate = maxRate or 7.44
	steps = steps or 20
	local txDev = device.config(txPort, 2, 2)
	local rxDev = device.config(rxPort, 2, 2)
	local txQueue = txDev:getTxQueue(0)
	local txQueueTs = txDev:getTxQueue(1)
	local rxQueueTs = rxDev:getRxQueue(1)
	rxDev:l2Filter(0x1234, filter.DROP)
	device.waitForLinks()
	for rate = minRate, maxRate, (maxRate - minRate) / 20 do
		for i = 1, REPS do
			for method = 1, 2 do
				printf("Testing rate %f Mpps with %s rate control, test run %d", rate, method == 1 and "hardware" or "software", i)
				txQueue:setRateMpps(method == 1 and rate or 0)
				local loadTask = dpdk.launchLua("loadSlave", txQueue, rxDev, method == 2 and rate)
				local timerTask = dpdk.launchLua("timerSlave", txDev, rxDev, txQueueTs, rxQueueTs)
				local rate = loadTask:wait()
				local hist = timerTask:wait()
				dpdk.sleepMillis(500)
			end
			if not dpdk.running() then
				break
			end
		end
		if not dpdk.running() then
			break
		end
	end
end

function loadSlave(queue, rxDev, rate)
	-- TODO: this leaks memory as mempools cannot be deleted in DPDK
	local mem = memory.createMemPool(function(buf)
		buf:getEthernetPacket():fill{
			ethType = 0x1234
		}
	end)
	local bufs = mem:bufArray()
	local runtime = timer:new(RUN_TIME)
	local rxStats = stats:newRxCounter(rxDev, "plain")
	local txStats = stats:newTxCounter(queue, "plain")
	while runtime:running() and dpdk.running() do
		bufs:alloc(PKT_SIZE)
		if rate then
			for _, buf in ipairs(bufs) do
				buf:setRate(rate)
			end
			queue:sendWithDelay(bufs)
		else
			queue:send(bufs)
		end
		rxStats:update()
		txStats:update()
	end
	-- wait for packets in flight/in the tx queue
	dpdk.sleepMillis(500)
	txStats:finalize()
	rxStats:finalize()
	return rxStats
end

function timerSlave(txDev, rxDev, txQueue, rxQueue)
	local mem = memory.createMemPool()
	local buf = mem:bufArray(1)
	local rxBufs = mem:bufArray(2)
	txQueue:enableTimestamps()
	rxQueue:enableTimestamps()
	local hist = {}
	dpdk.sleepMillis(1000)
	local runtime = timer:new(RUN_TIME - 2)
	while runtime:running() and dpdk.running() do
		buf:alloc(PKT_SIZE)
		ts.fillL2Packet(buf[1])
		-- sync clocks and send
		ts.syncClocks(txDev, rxDev)
		txQueue:send(buf)
		-- increment the wait time when using large packets or slower links
		local tx = txQueue:getTimestamp(100)
		if tx then
			dpdk.sleepMicros(5000) -- minimum latency to limit the packet rate
			-- sent was successful, try to get the packet back (max. 10 ms wait time before we assume the packet is lost)
			local rx = rxQueue:tryRecv(rxBufs, 10000)
			if rx > 0 then
				local delay = (rxQueue:getTimestamp() - tx) * 6.4
				if delay > 0 and delay < 100000000 then
					hist[delay] = (hist[delay] or 0) + 1
				end
				rxBufs:freeAll()
			end
		end
	end
	local sortedHist = {}
	for k, v in pairs(hist) do 
		table.insert(sortedHist,  { k = k, v = v })
	end
	local sum = 0
	local samples = 0
	table.sort(sortedHist, function(e1, e2) return e1.k < e2.k end)
	print("Histogram:")
	for _, v in ipairs(sortedHist) do
		sum = sum + v.k * v.v
		samples = samples + v.v
		--print(v.k, v.v)
	end
	print()
	print("Average: " .. (sum / samples) .. " ns, " .. samples .. " samples")
	print("----------------------------------------------")
	io.stdout:flush()
	return hist
end

