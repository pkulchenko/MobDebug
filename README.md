# Project Description

MobDebug is a remote debugger for Lua (including Lua 5.1, Lua 5.2, Lua 5.3, and LuaJIT 2.x).

## Features

MobDebug allows to control the execution of another Lua program remotely,
set breakpoints, and inspect the current state of the program.

MobDebug is based on [RemDebug](http://www.keplerproject.org/remdebug/) and
extends it in several ways:

* added new commands: LOAD, RELOAD, OUT, STACK, DONE;
* added support for debugging wxwidgets applications;
* added ability to pause and abort running applications;
* added pretty printing and handling of multiple results in EXEC;
* added stack and local/upvalue value reporting (STACK);
* added on/off commands to turn debugging on and off (to improve performance);
* added support for coroutine debugging (see examples/README for details);
* added support for [Moai](http://getmoai.com/) debugging;
* added support for Lua 5.2 and Lua 5.3;
* added support for varargs in stack trace;
* added support for vararg expressions in EXEC;
* added support for LuaJIT debugging (see note in Dependencies);
* added support for nginx/OpenResty and Lapis debugging;
* added support for cross-platform debugging (with client and server running on different platforms/filesystems);
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

MobDebug depends on LuaSocket 2.0+ and has been tested with Lua 5.1, Lua 5.2, and Lua 5.3.
MobDebug also works with LuaJIT v2.0; using `loop` and `scratchpad` methods requires v2.0.1.

## Author

Paul Kulchenko (paul@kulchenko.com)

## License

See LICENSE file
