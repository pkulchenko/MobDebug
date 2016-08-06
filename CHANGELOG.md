# MobDebug Changelog

## v0.64 (Aug 06 2016)
  - Add callback mobdebug.onscratch (thanks to @dodo).
  - Added path normalization to file names that don't start with `@`.
  - Added populating vararg (`...`) values in the main chunk during debugging.
  - Added path normalization to handle paths with up-dir references.
  - Added `verbose` option to the `handle` method of the debugger.
  - Added `output` method to pass stream information back to the controller.
  - Improved error checking after OUTPUT command.
  - Updated to reference one source for all hook masks.
  - Updated `output` method not to fail when debugging is not started.
  - Updated output stream processing to allow for empty strings.
  - Updated `vararg` stack handling to work around incorrect LuaJIT 2.0.0 values.

## v0.63 (Jan 25 2016)
  - Added localization for `coroutine.wrap` call to allow modification (closes #17).
  - Added `onexit` callback and removed `os.exit` calls from the controller (#19).
  - Removed explicit assignment to `loaded` as this can be done only as needed (#23).
  - Switched to using `string.*` methods to avoid string metamethods in the debug hook.
  - Updated check for session completion to avoid early exit from debugging server (closes #24).
  - Updated tests to add `listw` and `listb` commands.
  - Upgraded Serpent (0.285) to add `keyignore` option.
  - Upgraded Serpent to add numerical format fix and `__tostring` protection.
  - Updated `DONE` response to allow for async processing (#19).
  - Updated information on Lua 5.3 in README.

## v0.62 (May 2 2015)
  - Added variable arguments (vararg) to the stack trace.
  - Updated examples to add `stack`, `basedir`, and `output` commands (closes #15).
  - Updated removing breakpoints to remove all after `DELALLB` command.
  - Upgraded Serpent to 0.28 with more `tostring` processing (thanks to @andrewstarks).
  - Added explicit `tostring` for Lua 5.3 with `LUA_NOCVTN2S` set (pkulchenko/ZeroBraneStudio#401).
  - Extended check for `mobdebug.loadstring` result (pkulchenko/ZeroBraneStudio#387).

## v0.61 (Nov 23 2014)
  - Added `basedir` method to explicitly set basedir when needed.
  - Added connection timeout and exposed `connect` method for customization.
  - Updated documentation for Lua 5.3 support and added features.
  - Updated error handling when starting debugging fails due to connection error.
  - Fixed `DONE` command to work with Lua 5.1 and 5.2 when breakpoints are set.
  - Fixed `DONE` command when executed in scratchpad.
  - Fixed `DONE` command to work from fragments loaded with `loop()`.
  - Fixed references to `debug` library for environments that don't have it loaded.

## v0.60 (Aug 30 2014)
  - Added support for nginx debugging using internal coroutine API.
  - Fixed localizaton in breakpoint handling function.
  - Added path processing for chunk names that look like file names.
  - Added line mapping support for debugging Lua-based languages.
  - Fixed compatibility with Lua 5.2 (#13).

## v0.56 (May 11 2014)
  - Added `pause` method to suspend debugging from the application.
  - Added DONE command to stop debugging and continue execution.
  - Updated handling of `os.getenv` that may return multiple values (fixes #13).
  - Updated coroutine debugging to avoid using `require` calls.
  - Added support for setting/deleting breakpoints at run-time.
  - Added number conversion for MOBDEBUG_PORT.
  - Added check for loading 'os' module that may be absent on some systems.
  - Updated Serpent (0.272) to fix array indexes serialization.
  - Added closing Lua state during os.exit() for Lua 5.2+ (closes #11).
  - explicit load Lua standard library (thanks to Alexey Melnichuk)
  - Added explicit loading of `table` table (fixes #9).

## v0.55 (Dec 14 2013)
  - Added `setbreakpoint` and `removebreakpoint` public methods (closes #8).
  - Fixed complex values 'captured' by redirected 'print' and not collected.
  - Fixed error reporting on debugging non-existing file.
  - Added ability to overwrite `line` and `dump` methods for serialization.
  - Added handling of case-sensitive partitions on OSX (fixes #6, closes #7).
  - Fixed Step Over/Out commands to stay in the same coroutine.
  - Updated LICENSE information.
  - Added optimization and limiting elements in a table in serializer (Serpent 0.25).
  - Added support for `MOAICoroutine.new().run` to enable coroutine debugging.
  - Added reporting of socket error for failed start()/loop() calls.
  - Fixed debugging on/off handling in 'main' thread for LuaJIT.
  - Fixed stepping through blocks with `nil` variables when 'strict' is in effect.

## v0.54 (Aug 30 2013)
  - Added reset of hook visits in case earlier start() call is refused.
  - Added saving host/port configuration to reuse in start/loop calls.
  - Added handling of code fragments reported as 'source'.
  - Improved handling of done() in environments that reuse VMs.
  - Reset state to allow multiple start()/done() calls from the same process.
  - Replaces `unpack` with `table.unpack` for Lua 5.2 compatibility.
  - Updated filenames/source code heuristic to avoid serializing filenames.
  - Upgraded Serpent to 0.24 to fix table serialization issue.
  - Upgraded Serpent to 0.231 to fix luaffi issue.
  - Fixed debugging of zero length scripts.

## v0.53 (May 06 2013)
  - Added handling of case-insensitive filenames on OSX.
  - Allowed start() to be called inside other functions (like assert).
  - Improved debugging performance.
  - Replaced socket.select with non-blocking .receive as it is faster.
  - Upgraded serializer to add notification on incomplete output.
  - Upgraded serializer (v0.224) to add support for __tostring and __serialize metamethods.
  - Updated to allow `debug.traceback()` to be called under debugger.
  - Fixed 'breaking' after executing OUT command that never reaches the target level.
  - Fixed terminating debugging of an empty script.
  - Fixed resetting cached source as it may change when basedir changes.
  - Fix stack trace when LuaJIT FFI data is present (add `cdata` handling).

## v0.52 (Mar 04 2013)
  - Added `done()` method to finish debugging and to allow the script to continue.
  - Added support for cross-platform remote debugging.
  - Added support for code reloading and coroutine debugging under LuaJIT (v2.0.1).
  - Added using `socket.connect4` when available.
  - Added support for debugging Lua 5.2 scripts.
  - Added check for `os.getenv` for those platforms that don't implement it.
  - Improved handling of run-time errors in serialized data (__tostring method).
  - Improved reporting of debugger errors to the application.
  - Moved mosync/mobileLua code into a separate module.
  - Fixed an issue with `eval/exec` commands not working immediately after `start()`.

## v0.51 (Dec 13 2012)
  - Added yield callback to customize event loop call during debugging.
  - Added custom error handler for start() call to report errors remotely.
  - Added serialization of remote 'print' results.
  - Added 'output' command to redirect 'print' remotely.
  - Added turning JIT off under LuaJIT to get reliable debug hook calls.
  - Added setting/using global vars in a way that is 'strict.lua' friendly.
  - Changed default port to 8172. Added setting port # using MOBDEBUG_PORT.
  - Updated license to add remdebug license information.
  - Upgraded to Serpent v0.20 to add serialization of metatables with 
    __tostring and fix serialization of functions as shared keys.
  - Fixed using correct environment after the main script is done.

## v0.50 (Oct 05 2012)
  - Improved path matching when absolute and relative paths are used.
  - Improved performance; thanks to Stephen Nichols for profiling and
    detailed suggestions.
  - Added conversion of file names on Windows to lower case to make
    x:\Foo and X:\foo to match in breakpoint checks.
  - Added reporting errors in deserializing stack data.
  - Fixed an issue with returning stack values with circular references.
  - Fixed serialization of usedata values that don't provide tostring().
  - Fixed an issue with wx IDLE event on Linux.

## v0.49 (Sep 03 2012)
  - Added support for unicode names in load and breakpoint commands.
  - Added conversion to short path for unicode names on windows.
  - Added handling of exit/load/reload commands after watch condition is fired.
  - Added support for moai breakpoints and callback debugging.
  - Fixed an issue of starting debugging too early in some cases using start().
  - Fixed an issue with coroutine debugging.
  - Fixed an issue with yielding to wxwidgets apps while running main loop.

## v0.48 (Aug 05 2012)
  - Added support for coroutine debugging. Added methods (coro/moai) to
    support coroutine debugging without adding 'on()' calls to all coroutines.
  - Added on/off methods to turn debugging on and off (to improve performance).
  - Fixed an issue with localized variables not being properly restored
    if there are multiple variables with the same name in the environment.
  - Added restoring variables between stack calls to make them reflect changes
    that can be caused by EXEC/EVAL commands.
  - Fixed compilation errors on scripts with a shebang line.

## v0.47 (Jun 28 2012)
  - Added special handling to debug clients running under LuaJIT.
  - Fixed an issue when a remote client could not suspend/exit.
  - Added default configuration for start/loop/listen methods.
  - Relaxed safety checks to allow debugging lua code called from C
    functions (to support debugging Love2d and similar applications).
  - Fixed incorrect initial stack level when started with start() command.
  - Added short_src field to the reported stack data.

## v0.46 (Jun 19 2012)
  - Added reporting of stack and variable (local/upvalue) information.
  - Added support for multiple results returned by EXEC/EVAL commands.
  - Added serialization/pretty-printing of results from EXEC/EVAL.

## v0.45 (May 28 2012)
  - Added select() implementation to mosync client to abort/break a running
    mosync app.
  - Added support for scratchpad.
  - Added SUSPEND command to suspend execution of a running script.
  - Added 'loadstring' command to load chunks of code to run under debugger.
  - Added safety mechanism to LOAD/RELOAD to avoid aborting when there are
    C functions in the stack.
  - Added reset for loaded modules to get 'require' to be processed correctly
    after LOAD/RELOAD commands.
  - Added integration with MobileLua event loop to allow debugging of
    applications that require event loop processing.
  - Improved handling and reporting of run-time errors during debugging.
  - Fixed handling of multi-line fragments with comments executed with EXEC/EVAL.
  - Fixed exit from the debugger when the application throws an error.
  - Fixed an issue with saving/restoring internal local variables.
  - Fixed an issue with local variables not being updated after EXEC/EVAL
    commands.

## v0.44 (Mar 20 2012)
  - Updated to work with "mosync" namespace (MobileLua 20120319 and MoSync 3.0).
  - Removed the use of "module()".

## v0.43 (Jan 16 2012)
  - Fixed errors from LOAD/RELOAD commands when used with start() method.
  - Added reporting of a file name and a line number to properly display
    source code when attach to a debugger.

## v0.42 (Dec 30 2011)
  - Added support for debugging of wxwidgets applications.
  - Added ability to break an application being debugged; this requires
    socket.select and async processing (doesn't work from the command line).

## v0.41 (Dec 17 2011)
  - Added slash conversion in filenames to make breakpoints work regardless
    of how slashes are specified in file names and in setb/delb commands.
  - Added tests with breakpoints in files in subfolders.
  - Added optimization for filename processing in the debug hook
    (Christoph Kubisch).
  - Added conversion of newlines for EVAL/EXEC commands to make them work
    with multiline expressions.
  - Allowed 'setb' and 'delb' commands to accept '-' as the filename.
    The last referenced (checked/stopped at/etc.) filename is used.

## v0.40 (Dec 02 2011)
  - First public release.
