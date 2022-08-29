# Project Description

MobDebug is a remote debugger for Lua (including Lua 5.1, Lua 5.2, Lua 5.3, Lua 5.4, and LuaJIT 2.x).

## Features

MobDebug allows to control the execution of another Lua program remotely,
set breakpoints, and inspect the current state of the program.

Mobdebug is a cross-platform debugger, which not only works on Windows, macOS, and Linux, but
also supports debugging with the application and debugger running on different platforms.

It also supports source maps, which allows debugging of Lua-based languages,
like [Moonscript](http://notebook.kulchenko.com/zerobrane/moonscript-debugging-with-zerobrane-studio)
and [GSL-shell](http://notebook.kulchenko.com/zerobrane/gsl-shell-debugging-with-zerobrane-studio).

MobDebug is based on [RemDebug](http://www.keplerproject.org/remdebug/) and
extends it in several ways:

* added support for Lua 5.2, Lua 5.3, and Lua 5.4;
* added support for LuaJIT debugging;
* added support for cross-platform debugging (client and server running on different platforms/filesystems);
* added new commands: LOAD, RELOAD, OUT, STACK, DONE;
* added ability to pause and abort running applications;
* added pretty printing and handling of multiple results in EXEC;
* added stack and local/upvalue value reporting (STACK);
* added on/off commands to turn debugging on and off (to improve performance);
* added support for coroutine debugging (see examples/README for details);
* added support for varargs in stack trace;
* added support for vararg expressions in EXEC;
* added support for source maps;
* added support for debugging nginx/OpenResty, Lapis, and wxwidgets applications;
* removed dependency on LuaFileSystem;
* provided integration with [ZeroBrane Studio IDE](http://studio.zerobrane.com/).

## Usage

```lua
-- to start a server you can use to debug your application
> lua -e "require('mobdebug').listen()"

-- to debug a script, add the following line to it:
require("mobdebug").start()
```

## Installation

Make `src/mobdebug.lua` available to your script.
See `examples/README` and `examples/*.lua` for examples of how to use the module.

## Dependencies

MobDebug depends on LuaSocket 2.0+ and has been tested with Lua 5.1, Lua 5.2, Lua 5.3, and Lua 5.4.
MobDebug also works with LuaJIT v2.0+; using `loop` and `scratchpad` methods requires v2.0.1.

## Troubleshooting

Generally, breakpoints set with in the debugger should work without any additional configuration,
but there may be cases when this doesn't work out of the box, which may happen for several reasons:

- A breakpoint may be **inside a coroutine**; by default breakpoints inside coroutines are not triggered.
To enable debugging in coroutines, including triggering of breakpoints, you may either
(1) add `require('mobdebug').on()` call to that coroutine, which will enable debugging for that particular coroutine, or
(2) add `require('mobdebug').coro()` call to your script, which will enable debugging for all coroutines created using `coroutine.create` later in the script.
- If you enable coroutine debugging using `require('mobdebug').coro()`, this will **not affect coroutines created using C API** or Lua code wrapped into `coroutine.wrap`.
You can still debug those fragments after adding `require('mobdebug').on()` to the coroutine code. 
- The path of the file known to the debugger (the caller of `setb` command) **may not be the same** as the path known to the Lua engine (running the code being debugged).
For example, if you use an embedded engine, you may want to check if the path reported by the engine is normalized (doesn't include `../` references) by checking the result of `debug.getinfo(1,"S").source`.
- The capitalization of the file known to the debugger **may not be the same** as the capitalization of the file known to the Lua engine with the latter running on a case-sensitive system.
For example, if you set a breakpoint on the file `TEST.lua` in the debugger running on Window (case-insensitive), it may not fire in the application running `test.lua` on Linux (with case-sensitive file system).
To avoid this make sure that the capitalization for your project files is the same on both file systems.
- The script you are debugging may **change the current folder** (for example, using `lfs` module) and load the script (using `dofile`) from the changed folder.
To make breakpoints work in this case you may want to **use absolute path** with `dofile`.
- You may have a symlink in your path and be referencing paths to your scripts differently in the code and in the debugger (using a path with symlink in one case and not using it in the other case).
- You may be using your own Lua engine that doesn't report file names relative to the project directory (as set in the debugger).
For example, you set the project directory pointing to `scripts` folder (with `common` subfolder) and the engine reports the file name as `myfile.lua` instead of `common/myfile.lua`;
the debugger will be looking for `scripts/myfile.lua` instead of `scripts/common/myfile.lua` and the file will not be activated and the breakpoints won't work.
You may also be using inconsistent path separators in the file names; for example, `common/myfile.lua` in one case and `common\myfile.lua` in another.
- If you are loading files using `luaL_loadbuffer`, make sure that the chunk name specified (the last parameter) matches the file location.
- If you set/remove breakpoints while the application is running, these changes may not have any effect if only a small number of Lua commands get executed.
To limit the negative impact of socket checks for pending messages, the debugger in the application only checks for incoming requests every 200 statements (by default), so if your tests include fewer statements, then `pause`/`break` commands and toggling breakpoints without suspending the application may not work.
To make the debugger to check more frequently, you can update `checkcount` field (`require('mobdebug').checkcount = 1`) before or after debugging is started.

## Author

Paul Kulchenko (paul@kulchenko.com)

## License

See LICENSE file
