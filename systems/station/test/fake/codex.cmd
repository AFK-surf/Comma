@ECHO off
REM The fake codex (codex.mjs) on Windows, as npm puts a command there (cmd-shim): the station runs the script with Node.
SET dp0=%~dp0
SET "_prog=node"
"%_prog%"  "%dp0%\codex.mjs" %*
