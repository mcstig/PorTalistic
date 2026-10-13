#!/usr/bin/env bash
# (selftest: may run during a game)
# gdb-check: whether a debugger can look inside Steam's overlay UI here (gdb present, ptrace allowed)
set -u
command -v gdb && gdb --version | head -1
cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null
dnf list --installed gdb 2>/dev/null | tail -1
pgrep -a -f "steamrtarm64/gameoverlayui" | cut -c1-150
