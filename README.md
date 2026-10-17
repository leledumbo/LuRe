# LuRe - Lua Reimplemented
In Pascal.

# Description
I used to have this desire to reimplement Lua in Pascal. The language is concise, compact, and yet featureful, and resembles some Pascal spirit.
In fact, many Pascal based projects use Lua as its scripting engine (e.g.: Cheat Engine, Double Commander).

OTOH, in this age of AI coding boom, I'm evaluating their capabilities as well. This one is a "victim" of DeepSeek V4 Pro Max.
I'm asking it to build with a clean room approach, taking a peek at the original source code only for reference / inspiration.
The target is to pass the whole test suite, assuming that's enough to claim a feature parity with the original.
The implementation will not be a direct file to file conversion and instead, written in a typical modern Pascal style.

The current interpreter is working somewhat, but is extremely slow due to compliance first focus. Once it's fully compliant, the target can shift
to performance while keeping what modern Pascal implementation works best at: memory utilization. In the era of high memory price, it's the one
that can save your budget.
