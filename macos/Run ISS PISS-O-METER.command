#!/bin/bash
# Double-click in Finder (or run in Terminal) to launch the menu-bar app via the
# Apple-signed Swift toolchain. Keep this Terminal window open while it runs;
# for a permanent install, use build-app.sh instead.
cd "$(dirname "$0")"
exec swift IssPissOMeter.swift
