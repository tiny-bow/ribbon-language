#!/usr/bin/bash

clear

zig build run -freference-trace --prominent-compile-errors
