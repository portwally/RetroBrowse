#!/bin/sh
# Builds and runs the disk writer, parser and view model tests without Xcode's test runner.
# The app target has no test bundle, so the sources under test are compiled
# directly together with Tests/WriterTests/main.swift.
set -e
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/probrowse-writer-tests"
swiftc -swift-version 5 -Onone -o "$OUT" \
    ProBrowse/ProDOSWriter.swift \
    ProBrowse/DOS33Writer.swift \
    ProBrowse/DiskImageParser.swift \
    ProBrowse/DiskCatalogModels.swift \
    ProBrowse/ProDOSFileTypes.swift \
    ProBrowse/GzipZipArchive.swift \
    ProBrowse/NuFXArchive.swift \
    ProBrowse/BinaryIIArchive.swift \
    ProBrowse/UCSDPascalParser.swift \
    ProBrowse/FocusManager.swift \
    ProBrowse/DiskPaneViewModel.swift \
    Tests/WriterTests/main.swift
"$OUT" "$@"
