package = "MobDebug"
version = "0.60-1"

source = {
   url = "git://github.com/pkulchenko/MobDebug.git",
   tag = "0.60"
}

description = {
   summary = "MobDebug is a remote debugger for the Lua programming language",
   detailed = [[
      MobDebug allows you control the execution of another Lua program remotely,
      set breakpoints, and inspect the current state of the program.

      MobDebug is based on [RemDebug](http://www.keplerproject.org/remdebug/) and
      extends it in several ways:

      * fixed several existing bugs;
      * removed dependency on LuaFileSystem;
      * added new commands: LOAD, RELOAD, OUT, STACK;
      * added support for debugging wxwidgets applications;
      * added ability to pause and abort running applications;
      * added pretty printing and handling of multiple results in EXEC;
      * added stack and local/upvalue value reporting (STACK);
      * added on/off commands to turn debugging on and off (to improve performance);
      * added support for coroutine debugging (see examples/README for details);
      * added support for [Moai](http://getmoai.com/) debugging;
      * added support for Lua 5.2;
      * added support for LuaJIT debugging;
      * added support for cross-platform debugging (with client and server running on different platforms/filesystems);
      * tested integration with [ZeroBrane Studio IDE](http://studio.zerobrane.com/).
   ]],
   license = "MIT/X11",
   homepage = "https://github.com/pkulchenko/MobDebug"
}

dependencies = {
   "lua >= 5.1, < 5.3",
   "luasocket >= 2.0"
}

build = {
   type = "none",
   install = {
      lua = { ["mobdebug"] = "src/mobdebug.lua" }
   },
   copy_directories = { "examples" }
}
