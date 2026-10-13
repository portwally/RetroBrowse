//
//  NuFXParser.swift
//  ProBrowse
//
//  Native Swift parser for NuFX (ShrinkIt) archives (.sdk, .shk, .bxy)
//  Uses NuFXArchive for extraction
//

import Foundation

class NuFXParser {

    // MARK: - Public Interface

    /// Check if data appears to be a NuFX archive
    static func isNuFXArchive(_ data: Data) -> Bool {
        return NuFXArchive.isNuFXArchive(data)
    }

    /// Check file extension for ShrinkIt formats
    static func isShrinkItExtension(_ ext: String) -> Bool {
        let lower = ext.lowercased()
        return lower == "sdk" || lower == "shk" || lower == "bxy" || lower == "bny" || lower == "bqy"
    }

    /// Extract disk image from NuFX archive
    /// Returns the raw disk image data, or nil if extraction fails
    static func extractDiskImage(from url: URL) -> Data? {
        guard let archiveData = try? Data(contentsOf: url) else {
            print("❌ NuFX: Cannot read file")
            return nil
        }

        guard NuFXArchive.isNuFXArchive(archiveData) else {
            print("❌ NuFX: Invalid signature")
            return nil
        }

        // Use native NuFXArchive for extraction
        let archive = NuFXArchive(data: archiveData)

        do {
            try archive.parse()
            print("📦 NuFX: Parsed \(archive.records.count) records")

            // Look for disk image thread first
            for record in archive.records {
                if let diskThread = record.threads.first(where: { $0.isDiskImage }) {
                    print("   Found disk image thread: \(record.filename)")
                    let extracted = try archive.extractThread(diskThread, of: record)
                    print("   ✅ Extracted \(extracted.count) bytes")
                    return padToFloppySize(extracted)
                }
            }

            // Fall back to first data fork that looks like a disk image
            for record in archive.records {
                if let dataThread = record.dataForkThread {
                    let extracted = try archive.extractThread(dataThread, of: record)
                    // Check if it's a plausible disk image size
                    if [143360, 163840, 819200, 1638400].contains(extracted.count) ||
                       extracted.count >= 143360 {
                        print("   Using data fork as disk image: \(record.filename)")
                        print("   ✅ Extracted \(extracted.count) bytes")
                        return padToFloppySize(extracted)
                    }
                }
            }

            print("❌ NuFX: No disk image found in archive")
            return nil

        } catch {
            print("❌ NuFX extraction error: \(error)")
            return nil
        }
    }

    /// Extract all records from a NuFX archive
    static func extractRecords(from data: Data) -> [NuFXRecord]? {
        guard NuFXArchive.isNuFXArchive(data) else { return nil }

        let archive = NuFXArchive(data: data)
        do {
            try archive.parse()
            return archive.records
        } catch {
            return nil
        }
    }

    /// Extract a specific file from a NuFX archive
    static func extractFile(from data: Data, filename: String) -> Data? {
        guard NuFXArchive.isNuFXArchive(data) else { return nil }

        let archive = NuFXArchive(data: data)
        do {
            try archive.parse()

            // Find record with matching filename
            for record in archive.records {
                if record.filename.lowercased() == filename.lowercased() {
                    return try archive.extractData(for: record)
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private static func padToFloppySize(_ data: Data) -> Data {
        // Standard floppy sizes
        let sizes = [143360, 163840, 819200, 1638400]

        // Find smallest size that fits
        for size in sizes {
            if data.count <= size {
                if data.count == size {
                    return data
                }
                var padded = data
                padded.append(contentsOf: [UInt8](repeating: 0, count: size - data.count))
                return padded
            }
        }

        // Return as-is if larger than all standard sizes
        return data
    }
}
