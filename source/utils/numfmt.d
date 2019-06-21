/**
Copyright: Copyright (c) 2017-2019 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module utils.numfmt;

import utils : Duration;

/// Use 'i' format char to get binary prefixes (like Ki, instead of K), only for integers
/// Use '#' flag to get greek letter in the output (not compatible with 'i')
struct ScaledNumberFmt(T)
{
	import utils : min;
	import std.format : formattedWrite, FormatSpec;
	T value;
	void toString(scope void delegate(const(char)[]) sink, const ref FormatSpec!char fmt)
	{
		if (fmt.spec == 'i') {
			// Use binary prefixes instead of decimal prefixes
			import std.math: abs;
			long intVal = cast(long)value;
			int scale = calcScale2(intVal);
			double divisor = 1 << scale;
			double scaledValue = value / divisor;
			int digits = numDigitsInNumber10(scaledValue);
			string prefix = scalePrefixesAscii[scaleToScaleIndex2(scale)]; // length is 1 or 0
			int precision = min(3-digits, fmt.precision); // gives 0 or 1
			int width = fmt.width - (cast(int)prefix.length * 2); // account for 'i' prefix
			string fmtString = (scale == 0) ? "%*.*f%s" : "%*.*f%si";
			sink.formattedWrite(fmtString, width, precision, scaledValue, prefix);
		} else {
			int scale = calcScale10(value);
			auto scaledValue = scaled10(value, -scale);
			int digits = numDigitsInNumber10(scaledValue);
			immutable string[] prefixes = (fmt.flHash) ? scalePrefixesGreek : scalePrefixesAscii;
			string prefix = prefixes[scaleToScaleIndex10(scale)]; // length is 1 or 0
			int width = fmt.width - cast(int)prefix.length;
			int precision = min(3-digits, fmt.precision); // gives 0 or 1
			sink.formattedWrite("%*.*f%s", width, precision, scaledValue, prefix);
		}
	}
}

auto scaledNumberFmt(T)(T value)
{
	return ScaledNumberFmt!T(value);
}

auto scaledNumberFmt(Duration value, double scale = 1)
{
	double seconds = value.total!"nsecs" / 1_000_000_000.0;
	return ScaledNumberFmt!double(seconds * scale);
}

// -30 .. 30, with step of 3. Or -10 to 10 with step of 1
immutable string[] scalePrefixesAscii = ["q","r","y","z","a","f","p","n","u","m","","K","M","G","T","P","E","Z","Y","R","Q"];
immutable string[] scalePrefixesGreek = ["q","r","y","z","a","f","p","n","µ","m","","K","M","G","T","P","E","Z","Y","R","Q"];
enum NUM_SCALE_PREFIXES = 10;
enum MIN_SCALE_PREFIX = -30;
enum MAX_SCALE_PREFIX = 30;


int numDigitsInNumber10(Num)(const Num val)
{
	import std.math: abs, round;
	ulong absVal = cast(ulong)val.abs.round;
	int numDigits = 1;

	while (absVal >= 10)
	{
		absVal /= 10;
		++numDigits;
	}

	return numDigits;
}

/// Returns number in range of [-30; 30]
int calcScale10(Num)(Num val)
{
	import std.algorithm: clamp;
	import std.math: abs, floor, ceil, log10;
	static int signum(T)(const T x) pure nothrow
	{
		return (x > 0) - (x < 0);
	}

	auto lg = log10(abs(val));
	int logSign = signum(lg);
	double absLog = abs(lg);

	int scale;
	if (lg < 0)
		scale = cast(int)(ceil(absLog/3.0))*3;
	else
		scale = cast(int)(floor(absLog/3.0))*3;

	int clampedScale = scale * logSign;
	if (clampedScale < MIN_SCALE_PREFIX)
		clampedScale = 0; // prevent zero, or values smaller that min scale to display with min scale
	else if (clampedScale > MAX_SCALE_PREFIX)
		clampedScale = MAX_SCALE_PREFIX;

	return clampedScale;
}

/// Returns number in range of [0; 100]
int calcScale2(Num)(Num val)
{
	import std.algorithm: clamp;
	import std.math: abs, floor, ceil, log2;
	static int signum(T)(const T x) pure nothrow
	{
		return (x > 0) - (x < 0);
	}

	auto lg = log2(abs(val));
	int logSign = signum(lg);
	double absLog = abs(lg);

	int scale;
	if (lg < 0)
		scale = cast(int)(ceil(absLog/10.0))*10;
	else
		scale = cast(int)(floor(absLog/10.0))*10;

	int clampedScale = scale * logSign;
	if (clampedScale < 0)
		clampedScale = 0; // negative scale should not happen for integer numbers
	else if (clampedScale > MAX_SCALE_PREFIX)
		clampedScale = MAX_SCALE_PREFIX;

	return clampedScale;
}

int scaleToScaleIndex10(int scale) {
	return scale / 3 + NUM_SCALE_PREFIXES; // -30...30 -> -10...10 -> 0...20
}

int scaleToScaleIndex2(int scale) {
	return scale / 10 + NUM_SCALE_PREFIXES; // -100...100 -> -10...10 -> 0...20
}

double scaled10(Num)(Num num, int scale)
{
	import std.math: pow;
	return num * pow(10.0, scale);
}