/**
Copyright: Copyright (c) 2018 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/

/// Liveness info analisys
module liveness;

import std.array : empty;
import std.string : format;
import std.stdio : writeln, write, writef, writefln, stdout;
import std.format : formattedWrite, FormatSpec;
import std.range : repeat;
import std.range : chain;
import std.bitmanip : bitfields;
import std.algorithm : min, max, sort, swap;

import all;

/// Implementation of:
/// "Linear Scan Register Allocation on SSA Form"

/*
// buildIntervals
for each block b in reverse order do
	live = union of successor.liveIn for each successor of b

	for each phi function phi of successors of b do
		live.add(phi.inputOf(b))

	for each opd in live do
		intervals[opd].addRange(b.from, b.to)

	for each operation op of b in reverse order do
		for each output operand opd of op do
			intervals[opd].setFrom(op.id)
			live.remove(opd)
		for each input operand opd of op do
			intervals[opd].addRange(b.from, op.id)
			live.add(opd)

	for each phi function phi of b do
		live.remove(phi.output)

	if b is loop header then
		loopEnd = last block of the loop starting at b
		for each opd in live do
			intervals[opd].addRange(b.from, loopEnd.to)
	b.liveIn = live
*/
//version = LivePrint;
void pass_live_intervals(ref CompilationContext context)
{
	import std.bitmanip : BitArray;
	// We store a bit array per basic block. Each bit shows liveness of operand per block
	// Padding aligns number of bits to multiple of size_t bits.
	// This way there is a whole number of size_ts per basic block
	// With padding we can copy size_t's directly between live and liveIn, without bit twiddling

	// [block0:[IrArgumentId..., padding], block1:[IrArgumentId..., padding]]
	BitArray liveIn;
	size_t[] liveInData;
	size_t[] liveInBuckets;

	// [IrArgumentId..., padding]
	BitArray live;
	size_t[] liveData;
	size_t[] liveBuckets;

	void allocSets(size_t numBucketsPerBlock, size_t numBlocks) {
		//writefln("alloc buckets %s blocks %s", numBucketsPerBlock, numBlocks);
		if (liveData.length < numBucketsPerBlock)
			liveData.length = numBucketsPerBlock;
		liveBuckets = liveData[0..numBucketsPerBlock];
		// liveData is nulled for each basic block, so we skip nulling
		live = BitArray(liveData, numBucketsPerBlock * size_t.sizeof * 8);

		size_t numBucketsTotal = numBucketsPerBlock * numBlocks;
		if (liveInData.length < numBucketsTotal)
			liveInData.length = numBucketsTotal;
		liveInData[] = 0; // unset all bits
		liveInBuckets = liveInData[0..numBucketsTotal];
		liveIn = BitArray(liveInData, numBucketsTotal * size_t.sizeof * 8);
	}

	foreach (FunctionDeclNode* fun; context.mod.functions)
	{
		IrFunction* ir = fun.lirData;
		context.assertf(ir.callingConvention !is null, "Calling convention is null");

		ir.assignSequentialBlockIndices();

		size_t numVregs = ir.numVirtualRegisters;
		size_t numBucketsPerBlock = divCeil(numVregs, size_t.sizeof * 8);
		allocSets(numBucketsPerBlock, ir.numBasicBlocks);

		fun.liveIntervals = new FunctionLiveIntervals();
		fun.liveIntervals.initIntervals(&context, ir);
		fun.liveIntervals.linearIndicies.create(&context, ir);

		// enumerate all basic blocks, instructions
		// phi functions use index of the block
		uint enumerationIndex = 0;
		enum ENUM_STEP = 2;
		foreach (IrIndex blockIndex, ref IrBasicBlockInstr block; ir.blocks)
		{
			version(LivePrint) writefln("[LIVE] %s %s", enumerationIndex, blockIndex);
			// Allocate index for block start
			fun.liveIntervals.linearIndicies[blockIndex] = enumerationIndex;
			enumerationIndex += ENUM_STEP;
			// enumerate instructions
			foreach(IrIndex instrIndex, ref IrInstrHeader instrHeader; block.instructions(ir))
			{
				version(LivePrint) writefln("[LIVE]   %s %s", enumerationIndex, instrIndex);
				fun.liveIntervals.linearIndicies[instrIndex] = enumerationIndex;
				enumerationIndex += ENUM_STEP;
			}
		}

		void liveAdd(IrIndex someOperand)
		{
			context.assertf(someOperand.isVirtReg, "not vreg, but %s", someOperand.kind);
			version(LivePrint) writefln("[LIVE] liveAdd %s #%s", someOperand, ir.getVirtReg(someOperand).seqIndex);
			live[ir.getVirtReg(someOperand).seqIndex] = true;
		}

		void liveRemove(IrIndex someOperand)
		{
			context.assertf(someOperand.isVirtReg, "not vreg, but %s", someOperand.kind);
			version(LivePrint) writefln("[LIVE] liveRemove %s #%s", someOperand, ir.getVirtReg(someOperand).seqIndex);
			live[ir.getVirtReg(someOperand).seqIndex] = false;
		}

		size_t[] blockLiveIn(IrIndex blockIndex)
		{
			size_t from = ir.getBlock(blockIndex).seqIndex * numBucketsPerBlock;
			size_t to = from + numBucketsPerBlock;
			return liveInBuckets[from..to];
		}

		// algorithm start
		// for each block b in reverse order do
		foreach (IrIndex blockIndex, ref IrBasicBlockInstr block; ir.blocksReverse)
		{
			uint phiInstrLinearPositions = fun.liveIntervals.linearIndicies[blockIndex];

			// live = union of successor.liveIn for each successor of block
			liveData[] = 0;
			foreach (IrIndex succIndex; block.successors.range(ir))
			{
				foreach (size_t i, size_t bucket; blockLiveIn(succIndex))
					liveBuckets[i] |= bucket;
			}

			// for each phi function phi of successors of block do
			//     live.add(phi.inputOf(block))
			foreach (IrIndex succIndex; block.successors.range(ir))
				foreach (IrIndex phiIndex, ref IrPhiInstr phi; ir.getBlock(succIndex).phis(ir))
					foreach (i, ref IrPhiArg arg; phi.args(ir))
						if (arg.basicBlock == blockIndex)
							if (arg.value.isVirtReg)
								liveAdd(arg.value);

			//writef("in @%s live:", fun.liveIntervals.linearIndicies[blockIndex]);
			//foreach (size_t index; live.bitsSet)
			//	writef(" %s", index);
			//writeln;

			// for each opd in live do
			foreach (size_t index; live.bitsSet)
			{
				// intervals[opd].addRange(block.from, block.to)
				IntervalIndex interval = fun.liveIntervals.intervalIndex(VregIntervalIndex(cast(uint)index));
				fun.liveIntervals.addRange(interval, phiInstrLinearPositions,
					fun.liveIntervals.linearIndicies[block.lastInstr]);
				version(LivePrint) writefln("[LIVE] addRange vreg.#%s [%s; %s)", index,
					phiInstrLinearPositions,
					fun.liveIntervals.linearIndicies[block.lastInstr]);
			}

			// for each operation op of b in reverse order do
			foreach(IrIndex instrIndex, ref IrInstrHeader instrHeader; block.instructionsReverse(ir))
			{
				uint linearInstrIndex = fun.liveIntervals.linearIndicies[instrIndex];

				// assign interval hints
				// if non-mov instruction assigns to phys register,
				// movs must follow instruction immidiately matching the order of results
				// if non-mov instruction accepts 1 or more phys registers, then
				// it must be preceded by movs from vregs to pregs in matching order
				// Example:
				// eax = v.20 // args[0]
				// ecx = v.45 // args[2]
				// edx, ecx = some_instr(eax, v.100, ecx) // edx is results[0]
				// v.200 = edx // results[0] (aka result)
				// v.300 = ecx // results[1]
				bool isMov = context.machineInfo.instrInfo[instrHeader.op].isMov;
				if (isMov)
				{
					IrIndex from = instrHeader.args[0];
					IrIndex to = instrHeader.result;
					if (from.isPhysReg && to.isVirtReg)
					{
						auto vii = VregIntervalIndex(ir.getVirtReg(to).seqIndex);
						fun.liveIntervals.setVirtRegHint(vii, from);
					}
					else if (from.isVirtReg && to.isPhysReg)
					{
						auto vii = VregIntervalIndex(ir.getVirtReg(from).seqIndex);
						fun.liveIntervals.setVirtRegHint(vii, to);
					}
				}
				else
				{
					if (instrHeader.hasResult && instrHeader.result.isPhysReg)
					{
						// add fixed interval to the next instr
						IntervalIndex interval = fun.liveIntervals.intervalIndex(PregIntervalIndex(instrHeader.result));
						fun.liveIntervals.addRange(interval, linearInstrIndex, linearInstrIndex+2);
					}
				}

				// for each output operand opd of op do
				if (instrHeader.hasResult)
				{
					if (instrHeader.result.isVirtReg)
					{
						// intervals[opd].setFrom(op.id)
						auto vii = VregIntervalIndex(ir.getVirtReg(instrHeader.result).seqIndex);
						fun.liveIntervals.setFrom(vii, instrHeader.result, linearInstrIndex);
						version(LivePrint)
							writefln("[LIVE] setFrom vreg.#%s %s",
								ir.getVirtReg(instrHeader.result).seqIndex, linearInstrIndex);
						// live.remove(opd)
						liveRemove(instrHeader.result);
					}
					else if (instrHeader.result.isPhysReg && !isMov)
					{
						// non-mov, extend fixed interval to the next instr (which must be mov from that phys reg)
						IntervalIndex interval = fun.liveIntervals.intervalIndex(PregIntervalIndex(instrHeader.result));
						fun.liveIntervals.addRange(interval, linearInstrIndex, linearInstrIndex+2);
					}
				}

				int numPhysRegArgs = 0;
				// for each input operand opd of op do
				foreach(IrIndex arg; instrHeader.args)
				{
					if (arg.isVirtReg)
					{
						// intervals[opd].addRange(b.from, op.id)
						auto vii = VregIntervalIndex(ir.getVirtReg(arg).seqIndex);
						IntervalIndex interval = fun.liveIntervals.intervalIndex(vii);
						fun.liveIntervals.addRange(interval, phiInstrLinearPositions, linearInstrIndex);
						version(LivePrint) writefln("[LIVE] addRange vreg.#%s [%s; %s)",
							ir.getVirtReg(arg).seqIndex, phiInstrLinearPositions, linearInstrIndex);

						// live.add(opd)
						liveAdd(arg);
					}
					else if (arg.isPhysReg)
					{
						++numPhysRegArgs;
					}
				}

				if (!isMov)
				{
					foreach(IrIndex arg; instrHeader.args)
					{
						if (arg.isPhysReg)
						{
							// non-mov, extend fixed interval to the preceding mov instr
							IntervalIndex interval = fun.liveIntervals.intervalIndex(PregIntervalIndex(arg));
							fun.liveIntervals.addRange(interval, linearInstrIndex - numPhysRegArgs*2, linearInstrIndex);
							--numPhysRegArgs;
						}
					}
				}

				// TODO: add fixed intervals fo function calls
				//fun.liveIntervals.addRange(intId, linearInstrIndex, linearInstrIndex);
			}

			// for each phi function phi of b do
			foreach(IrIndex phiIndex, ref IrPhiInstr phi; block.phis(ir))
			{
				// live.remove(phi.output)
				if (phi.result.isVirtReg) {
					liveRemove(phi.result);
					auto vii = VregIntervalIndex(ir.getVirtReg(phi.result).seqIndex);
					fun.liveIntervals.setFrom(vii, phi.result, phiInstrLinearPositions);
				}
			}

			// TODO
			// if b is loop header then
			//     loopEnd = last block of the loop starting at b
			//     for each opd in live do
			//         intervals[opd].addRange(b.from, loopEnd.to)

			// b.liveIn = live
			blockLiveIn(blockIndex)[] = liveBuckets;
		}

		version(LivePrint)
		{
			TextSink sink;
			fun.liveIntervals.dump(sink);
			writeln(sink.text);
		}
	}
}


///
struct FunctionLiveIntervals
{
	// invariant: all ranges of one interval are sorted by `from` and do not intersect
	Buffer!LiveRange ranges;
	LiveInterval[] intervals;
	size_t numFixedIntervals;
	/// instructionIndex -> seqIndex
	/// blockIndex -> seqIndex
	IrMirror!uint linearIndicies;

	LiveInterval[] virtualIntervals() { return intervals[numFixedIntervals..$]; }
	LiveInterval[] physicalIntervals() { return intervals[0..numFixedIntervals]; }

	void initIntervals(CompilationContext* context, IrFunction* ir) {
		numFixedIntervals = context.machineInfo.registers.length;
		intervals.length = numFixedIntervals + ir.numVirtualRegisters;
		foreach (i, ref it; physicalIntervals)
		{
			it.reg = context.machineInfo.registers[i].index;
			it.isFixed = true;
		}
		ranges.reserve(ir.numVirtualRegisters);
	}

	/// Set hint for register allocator
	void setVirtRegHint(VregIntervalIndex vii, IrIndex hint) {
		intervals[intervalIndex(vii)].storageHint = hint;
	}

	bool intervalCoversPosition(NodeIndex cur, int position)
	{
		while (!cur.isNull)
		{
			auto r = &ranges[cur];
			if (position < r.from)
				return false;
			else if (position >= r.to)
				cur = r.nextIndex;
			else // from <= position < to
				return true;
		}
		return false;
	}

	int firstIntersection(NodeIndex a, NodeIndex b)
	{
		while (true)
		{
			auto ra = &ranges[a];
			auto rb = &ranges[b];
			if (ra.intersectsWith(*rb)) {
				return max(ra.from, rb.from);
			}
			else if (ra.from < rb.from) {
				a = ra.nextIndex;
				if (a.isNull) return int.max;
			}
			else { // rb.from > ra.from
				b = rb.nextIndex;
				if (b.isNull) return int.max;
			}
		}
	}

	ref LiveInterval opIndex(NodeIndex rangeId) { return intervals[ranges[rangeId].intervalIndex]; }
/*
	ref LiveInterval opIndex(IntervalIndex intId) { return intervals[intId]; }
	ref LiveInterval opIndex(IrOperandId opdId) { return intervals[numFixedIntervals + opdId]; }

	IntervalIndex intervalIndex(NodeIndex rangeId) { return ranges[rangeId].intervalIndex; }
	IntervalIndex intervalIndex(IrOperandId opdId) { return IntervalIndex(numFixedIntervals + opdId); }
	IrOperandId operandId(NodeIndex rangeId) { return operandId(ranges[rangeId].intervalIndex); }
	IrOperandId operandId(IntervalIndex intId) {
		assert(intId >= numFixedIntervals);
		return IrOperandId(intId- numFixedIntervals);
	}
*/
	IntervalIndex intervalIndex(PregIntervalIndex regRef) {
		return IntervalIndex(regRef.index);
	}
	IntervalIndex intervalIndex(VregIntervalIndex virtInterval) {
		return IntervalIndex(numFixedIntervals + virtInterval);
	}

	// returns rangeId pointing to range covering position or one to the right of pos.
	// returns -1 if no ranges left after pos.
	NodeIndex advanceRangeId(NodeIndex cur, int position)
	{
		while (!cur.isNull)
		{
			auto r = &ranges[cur];
			if (position < r.from)
				return cur;
			else if (position >= r.to)
				cur = r.nextIndex;
			else // from <= position < to
				return cur;
		}
		return cur;
	}

	// bounds are from block start to block end of the same block
	// from is always == to block start
	void addRange(IntervalIndex interval, int from, int to)
	{
		LiveRange newRange = LiveRange(from, to, interval);
		NodeIndex firstMergeId;

		// merge all intersecting ranges into one
		NodeIndex cur = intervals[interval].first;
		while (!cur.isNull)
		{
			auto r = &ranges[cur];

			if (r.canBeMergedWith(newRange))
			{
				if (firstMergeId.isNull)
				{
					// first merge
					firstMergeId = cur;
					r.merge(newRange);
				}
				else
				{
					// second+ merge
					ranges[firstMergeId].merge(*r);
					cur = deleteRange(cur); // sets cur to next range
					continue;
				}
			}
			else if (to < r.from)
			{
				if (!firstMergeId.isNull) return; // don't insert after merge

				// we found insertion point before cur, no merge was made
				insertRangeBefore(cur, newRange);
				return;
			}

			cur = r.nextIndex;
		}

		if (firstMergeId.isNull)
		{
			// insert after last (cur is NULL), no merge/insertion was made
			appendRange(interval, newRange);
		}
	}

	// sets the definition position
	void setFrom(VregIntervalIndex vii, IrIndex virtReg, int from) {
		IntervalIndex interval = intervalIndex(vii);
		intervals[interval].definition = virtReg;
		NodeIndex cur = intervals[interval].first;
		if (!cur.isNull) {
			ranges[cur].from = from;
		}
	}

	void insertRangeBefore(NodeIndex beforeRange, LiveRange range)
	{
		NodeIndex index = NodeIndex(ranges.length);

		LiveRange* next = &ranges[beforeRange];
		range.prevIndex = next.prevIndex;
		range.nextIndex = beforeRange;
		next.prevIndex = index;

		if (!range.prevIndex.isNull)
			ranges[range.prevIndex].nextIndex = index;
		else
			intervals[range.intervalIndex].first = index;

		ranges.put(range);
	}

	void appendRange(IntervalIndex interval, LiveRange range)
	{
		NodeIndex last = intervals[interval].last;
		NodeIndex index = NodeIndex(ranges.length);

		if (last.isNull)
		{
			intervals[range.intervalIndex].first = index;
			intervals[range.intervalIndex].last = index;
		}
		else
		{
			LiveRange* prev = &ranges[last];
			range.prevIndex = last;
			range.nextIndex = prev.nextIndex;
			prev.nextIndex = index;

			if (!range.nextIndex.isNull)
				ranges[range.nextIndex].prevIndex = index;
		}

		ranges.put(range);
	}

	void moveRange(NodeIndex fromIndex, NodeIndex toIndex)
	{
		if (fromIndex == toIndex) return;
		ranges[toIndex] = ranges[fromIndex];
		auto range = &ranges[toIndex];
		if (!range.prevIndex.isNull) ranges[range.prevIndex].nextIndex = toIndex;
		if (!range.nextIndex.isNull) ranges[range.nextIndex].prevIndex = toIndex;
		auto it = &intervals[range.intervalIndex];
		if (fromIndex == it.first) it.first = toIndex;
		if (fromIndex == it.last) it.last = toIndex;
	}

	// returns rangeId of the next range
	NodeIndex deleteRange(NodeIndex rangeIndex)
	{
		auto range = &ranges[rangeIndex];

		auto it = &intervals[range.intervalIndex];
		if (rangeIndex == it.first) it.first = range.nextIndex;
		if (rangeIndex == it.last) it.last = range.prevIndex;

		NodeIndex lastIndex = NodeIndex(ranges.length-1);
		NodeIndex nextIndex = range.nextIndex;

		if (range.prevIndex != NodeIndex.NULL)
			ranges[range.prevIndex].nextIndex = range.nextIndex;
		if (range.nextIndex != NodeIndex.NULL)
			ranges[range.nextIndex].prevIndex = range.prevIndex;

		if (nextIndex == lastIndex) nextIndex = rangeIndex;

		moveRange(lastIndex, rangeIndex);
		ranges.unput(1);

		return nextIndex;
	}

	void dump(ref TextSink sink) {
		void dumpSub(LiveInterval[] intervals)
		{
			foreach (i, it; intervals) {
				NodeIndex cur = it.first;
				if (it.isFixed && cur.isNull) continue;

				if (it.isFixed) sink.put("  p");
				else sink.put("  v");

				if (cur.isNull) {
					sink.putfln("% 3s: null", i);
					continue;
				}

				if (it.reg.isDefined)
					sink.putf("% 3s [%2s]:", i, it.reg);
				else
					sink.putf("% 3s [no reg]:", i);

				while (!cur.isNull)
				{
					auto r = &ranges[cur];
					sink.putf(" [%s; %s)", r.from, r.to);
					cur = r.nextIndex;
				}
				sink.putln;
			}
		}
		sink.putln("intervals:");
		dumpSub(intervals[0..$]);
	}
}

///
struct LiveInterval
{
	NodeIndex first;
	NodeIndex last;
	IrIndex reg;
	IrIndex definition; // null if isFixed
	//RegClass regClass;
	bool isFixed;
	IrIndex storageHint;
}

struct IntervalIndex
{
	this(size_t idx) { index = cast(uint)idx; }
	uint index = uint.max;
	alias index this;
	enum NULL = IntervalIndex();
	bool isNull() { return index == uint.max; }
}

struct VregIntervalIndex
{
	this(size_t idx) { index = cast(uint)idx; }
	uint index = uint.max;
	alias index this;
	enum NULL = VregIntervalIndex();
	bool isNull() { return index == uint.max; }
}

struct PregIntervalIndex
{
	this(IrIndex physReg) {
		assert(physReg.isPhysReg);
		index = physReg.storageUintIndex;
	}
	uint index = uint.max;
	alias index this;
	enum NULL = PregIntervalIndex();
	bool isNull() { return index == uint.max; }
}

/// [from; to)
struct LiveRange
{
	int from;
	int to;
	IntervalIndex intervalIndex;
	NodeIndex prevIndex = NodeIndex.NULL;
	NodeIndex nextIndex = NodeIndex.NULL;
	bool isLast() { return nextIndex == NodeIndex.NULL; }
	bool contains(int pos) {
		if (pos < from) return false;
		if (pos >= to) return false;
		return true;
	}
	void merge(LiveRange other) {
		from = min(from, other.from);
		to = max(to, other.to);
	}
	bool canBeMergedWith(const LiveRange other) {
		if (to + 2 < other.from) return false;
		if (from > other.to + 2) return false;
		return true;
	}

	bool intersectsWith(const LiveRange other) {
		if (to <= other.from) return false;
		if (from >= other.to) return false;
		return true;
	}
}

struct NodeIndex {
	this(size_t id) { this.id = cast(uint)id; }
	enum NodeIndex NULL = NodeIndex(uint.max);
	uint id = uint.max;
	bool isNull() { return id == NULL; }
	alias id this;
}
