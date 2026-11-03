# LuRe - Lua Reimplemented
In Pascal.

# Description
I used to have this desire to reimplement Lua in Pascal. The language is concise, compact, and yet featureful, and resembles some Pascal spirit.
In fact, many Pascal based projects use Lua as its scripting engine (e.g.: Cheat Engine, Double Commander). This project implements 5.5.1 version
of the language.

# Approach
The code is first built by DeepSeek V4 Pro Max, taking a peek at the original source code for reference or inspiration, but implemented differently
using pure modern Pascal approach, with an explicit goal of passing the test suite. It is subsequently replaced by Claude Code Sonnet 5.5 because a
colleague offers me a free credit, a LOT of it, as well as because DeepSeek has difficulty passing even the first test case due to its misfocus on
passing the test suite first instead of making the implementation right first.

# Current State
## Compatibility
Everything is ready to use:
* Standalone interpreter
* Drop-in bindings (with p suffix, so luap instead of lua, lualibp instead of lualib, and lauxlibp instead of lauxlib)

You can simply replace uses clause with these and say goodbye to Lua dynamic library to ship or static library to link with your application.
The virtual machine implements the exact same bytecode instructions, so it's binary compatible with the original implementation.

## Performance
The Makefile includes bench target, expected to be compared against actual Lua 5.5.1, and is currently between 0.8-2.0 times the speed. The main issue
is with FPC's register allocator, not even the code generator, which allocates at max 4 registers to local variables before spiling to stack, despite
on x86_64, 16 general purpose registers are available and leading C compilers utilize them very well. Consider that 0.8 a luck, I don't even expect that
one to ever happen. FPC with LLVM backend is tested and can improve performance by around 25%, but the build process is currently broken from FPC itself,
where the linking step must be done manually so I deliberately don't commit the support, at least until they fix it.
