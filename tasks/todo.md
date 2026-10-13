# ProBrowse audit — findings and fix plan

Audit date: 2026-10-12, at commit `92c3925`. Read-only: no source was changed.

Method: clean Debug build (succeeds, 0 errors), plus a full read of all 38 Swift files.
Evidence level is marked per item:

- **[run]** reproduced by running the code or checking against a real image/archive
- **[read]** traced end to end in the source, not executed
- **[likely]** depends on a file format detail or runtime state that could not be checked

Paths are relative to `ProBrowse/`. "VM" is `DiskPaneViewModel.swift`.

## 1. Data loss and disk corruption

- [x] **DOS 3.3 free-sector bitmap read in the wrong byte order** — `DOS33Writer.swift:244-251`, `:291-298`. Sector S is confused with S^8, so adding a file can overwrite live data and deleting frees the wrong sectors. Fix: `bitmap = b0 << 8 | b1`, and write back the same way. [run, against `Stinger.dsk`]
- [x] **Wrong "track 0" sector map for DOS-ordered images** — `ProDOSWriter.swift:22`, `DiskImageParser.swift:18`. Block 7's second half comes from sector 0 instead of 15. Reads return corrupt data; deleting a file keyed at block 7 frees garbage block numbers. Fix: use the one standard map for all tracks. Same error in `UCSDPascalParser.swift:76-83` for blocks 8n and 8n+7. [run, against `ProDOS_2_4_2.dsk`; Pascal by derivation]
- [x] **Cut and paste deletes the originals even when the copy failed** — VM `858-950`, `1306-1325`; `DiskBrowserPane.swift:302-311`. Copy failures are only printed. Fix: return per-entry success and delete only what copied. [read]
- [x] **Cmd+V pastes into the inactive pane** — `ContentView.swift:112-130`, VM `1284-1341`. Copy left, click right, paste: files are duplicated back onto the source. With Cut the right pane is also replaced by the left disk. [read]
- [x] **Delete, rename and change-type find the file by bare name across the volume** — VM `1040`, `1171`, `1227`; `ProDOSWriter.swift:844`, `1237`, `1496`. Acting on `/GAMES/README` hits `/README`. Change-type only searches the root. Fix: pass the parent path or entry location. [read]
- [x] **ProDOS writer runs on non-ProDOS images** — VM `621-661` (Finder import), `1093` (New Folder), `1171` (rename), `1306` (paste picks the writer from the wrong pane). `ProDOSWriter` never validates the volume header. Fix: branch on the target format everywhere, refuse on Pascal, validate block 2 before writing. [run: `addFile` reported success and overwrote 3,559 bytes of a non-ProDOS file]
- [x] **Failed load keeps the old catalog under the new file path** — VM `93-94`, `268-272`. Later writes go to the file that failed to parse. Archive-backed images (`.zip`, `.gz`, `.shk`) are also written to as if they were raw images. Fix: set path and catalog together on success only; mark archive-backed images read-only. [read]
- [x] **Sapling files of 130,561–131,072 bytes are labelled tree** — `ProDOSWriter.swift:601-610`. The file becomes unreadable. Fix: pass the storage type from `addFile`. [read]
- [x] **Change-type on a DOS-ordered image writes 2 bytes into the wrong sector** — `ProDOSWriter.swift:1527-1541`, for the entry that straddles the 256-byte boundary. Also the only non-atomic write (`:1545`). Fix: go through `readBlock`/`writeBlock`. [read]
- [x] **Subdirectory header shows as a phantom file** — `DiskImageParser.swift:444-446`. Deleting it deletes the directory. Fix: skip storage type `$E`. [read]
- [x] **Deleting a directory or forked file leaks its blocks** — `ProDOSWriter.swift:875-918`. `decrementFileCount` (`:976`) also always decrements the volume header, not the owning directory. [read]
- [x] **Multi-file cut deletes only some files** — VM `1314-1325`, `DiskBrowserPane.swift:306-311`. Concurrent whole-image rewrites; last writer wins. Fix: delete sequentially. [read]
- [x] **Writer and parser disagree on sector order** — `ProDOSWriter.swift:32-39` assumes DOS order by extension and size; the parser detects it from content. Writes to a ProDOS-ordered `.dsk` hit scrambled blocks. [read]
- [x] **No bounds checks in `writeBlock` and `freeBlocks`** — `ProDOSWriter.swift:83-122`, `954-972`. Heap overflow on a truncated image. [read]

## 2. Crashes

- [x] **Duplicate dictionary key `0xE10000`** — `Disassembler65816.swift:425` and `:430`. Traps the first time the 65816 disassembler looks up an address, i.e. on opening almost any S16/EXE file. Fix: delete one entry. [run; also a compiler warning]
- [x] **Date encoding traps from 2028-01-01** — `ProDOSWriter.swift:1098`, `1182`, `1407`. `UInt16((year - 1900) << 9 …)` overflows. Already crashes today on non-Gregorian system calendars. Hits Create Image and New Folder. Fix: Gregorian calendar, `year % 100`. [read]
- [x] **`UInt8(tsListIdx * 122)` traps** — `DOS33Writer.swift:392`, adding a DOS 3.3 file over 93,696 bytes. [read]
- [x] **Squeeze decoder traps on the EOF leaf** — `NuFXArchive.swift:783`. Also treats the `0x90` run escape as end of data (`:784`). [run, synthetic]
- [x] **Inverted-range traps on truncated input** — `NuFXArchive.swift:370`, `GzipZipArchive.swift:214-216`, `DiskImageParser.swift:294-304` (2MG header). [run for the first two; read for 2MG]
- [x] **`Int.max` overflow** — `NuFXArchive.swift:473` (unused `chunkEnd`; traps in debug builds). [run]
- [x] **Teach decoder: negative index and unbounded loop** — `TeachDecoder.swift:312-313`, `226-254`. A bad length appends ~357 million styles on the main thread. [run]
- [x] **Font sample render traps on a non-monotonic location table** — `AppleIIgsFontDecoder.swift:404-410`. [run]
- [x] **Unbounded recursion and loops on cyclic directory chains** — `DiskImageParser.swift:475`; `ProDOSWriter.swift:429`, `472`, `730`, `771`, `815`. [read]

## 3. Features that do not work

- [x] **ShrinkIt archives never open** — `NuFXArchive.swift:15-16` signatures are plain ASCII; real ones are high-bit (`4E F5 46 E9 6C E5`). Behind that: thread offset wrong (`:197`), three LZW/2 errors (`:695`, `:641`, `:548-556`), LZW/1 chunk length (`:480`), and no CRC check. With all fixed, 23 of 23 real threads match their CRC. [run, against two real `.SHK` files; a patched copy is in the session scratchpad]
- [x] **Finder-made zips cannot be read** — `GzipZipArchive.swift:172-177`. Data-descriptor zips have zero sizes in the local header. Fix: parse the central directory. [run]
- [x] **Binary II header layout wrong** — `BinaryIIArchive.swift:96-108`. EOF is 3 bytes at +20, name length at +23. [run against a spec-built header; no real `.bny`]
- [x] **Archives and `.vol` cannot be opened from the UI** — `DiskBrowserPane.swift:52`, `455`, `495`. Dropping one imports it into the open disk as a BIN file. [read]
- [ ] **App-wide key monitor swallows Cmd+C/X/V/I** — `ContentView.swift:108-139`. Text fields cannot copy or paste, and Cmd+V behind a sheet writes to disk. [read] **Partly done: the monitor now ignores keys while a sheet, alert or text field is active and requires exactly Cmd. Still an event monitor rather than menu commands.**
- [x] **"Create Image" as `.2mg` writes no 2IMG header** — `CreateImageSheet.swift:250`, `ProDOSWriter.swift:1306-1334`. [read]
- [x] **DOS 3.3 files are interpreted with ProDOS type codes** — `FileInspectorSheet.swift:365-432`, `540-607`. BASIC is never detokenized; binaries show as text. DOS files also carry no header handling on copy (`DOS33Writer.swift:500-518`). [read]
- [x] **DOS 3.3 name handling** — names truncated at the first space (`DiskImageParser.swift:700`); `fileExists` can never match (`DOS33Writer.swift:668`); the lock emoji is stored in `entry.name` (`DiskImageParser.swift:740`). [read]
- [ ] **Disk Image Inspector / Verify is unreachable** — `ContentView.swift:16-17`, `89-94`. [read]
- [x] **Delete key, Cmd+O and Cmd+Shift+O are advertised but not wired** — `CatalogEntryRow.swift:265`, `ContentView.swift:176`, `293`. [read]

## 4. Wrong output

- [x] **ProDOS dates and times** — `DiskImageParser.swift:46`, `59-61`; writer `654-655`, `1104`. Years 0–39 show as 1900–1939; hour and minute are swapped on read and write. [run for year; read for time]
- [x] **Directory linkage fields** — `ProDOSWriter.swift:1129-1133`, `669-670`, `1211-1212`. Parent pointer, parent entry number and header pointer are wrong. [run against real entries]
- [x] **Graphics misdetected as MacPaint** — `AppleIIGraphicsDecoder.swift:178-191`, `221-226`. HGR/DHGR/SHR files with a black top-left render as 576×720 garbage. [run]
- [x] **Packed SHR with a black top area shows "Unknown"** — `AppleIIGraphicsDecoder.swift:584-586`, `611-617`. [run]
- [x] **640-mode APF decoded as 320 mode** — `AppleIIGraphicsDecoder.swift:722`, `798`, `855`. [read]
- [x] **Merlin viewer shifts columns on unlabelled lines** — `MerlinView.swift:94-148`. [run]
- [x] **Teach resource map parsed with the wrong layout** — `TeachDecoder.swift:143-176`. [likely]
- [ ] **AppleWorks** — tab-ruler records desynchronise the WP parse (`AppleWorksDecoder.swift:340-344`) [likely]; AWGS red and blue swapped (`:540-542`) [read]; only the first AWGS text block parsed (`:628-672`) [likely]; high-bit characters mapped to control codes (`:451-468`) [read]. **Partly done: record stepping, the AppleWorks 3 header bytes, inverse characters and the AWGS palette are fixed. Only the first AWGS text block is read.**
- [ ] **6502 disassembler** — a dozen wrong monitor labels (`Disassembler6502.swift:363-437`); no 65C02 opcodes. [read] **Partly done: labels corrected. 65C02 opcodes are still shown as `???`.**
- [x] **65816 "Native Mode" toggle has no effect** — `Disassembler65816.swift:476-480`, `502-507`. [read]
- [x] **File type labels** — `$C0`/`$C1` swapped, `$B0` wrong (`FileInfoSheet.swift:137-139`). [read]
- [x] **Teach / AWGS styled paragraphs render as side-by-side columns** — `TeachView.swift:74-82`, `AppleWorksView.swift:89-97`. [read]

## 5. Smaller issues

- [x] Multi-file Finder drop imports only the first file, always as BIN — `DiskBrowserPane.swift:439-466`. [read]
- [ ] Drag exports the selection, not the dragged row; self-drops are accepted — `DiskBrowserPane.swift:341-354`. [read] **Partly done: a drop onto the image the drag came from is ignored, and a drag with nothing selected takes the row. With a selection, the selection is still what is dragged.**
- [x] Shift-click selects hidden children of collapsed folders; selecting a folder plus its children copies the children twice — VM `408-426`, `517-529`. [read]
- [x] Paste, drag-copy and import always land in the volume root; every reload returns to root — VM `855`, `776`, `640`, `97`. [read]
- [x] Navigating into a nested folder from the expanded tree records the wrong path — VM `473-488`. [read]
- [x] Header "Size" reads the whole image on every view update — `DiskBrowserPane.swift:131`. [read]
- [x] Non-ASCII names pass validation — `CreateImageSheet.swift:22-46`, `ProDOSWriter.swift:147-151`. [read]
- [ ] No duplicate-name check in `createDirectory`; directories never grow past one block; renaming a directory leaves its header name stale — `ProDOSWriter.swift:1000-1050`, `468-496`, `1264-1285`. [read] **Partly done: duplicate check and directory-header rename are in. Directories still cannot grow past one block.**
- [x] Bitmap location hard-coded to block 6 — `ProDOSWriter.swift:524`, `955`. [read]
- [x] DOS 3.3 allocator can hand out track 0; catalog sector count omits T/S list sectors — `DOS33Writer.swift:228-236`, `567`. [likely / read]
- [x] Decompression size limits missing — `NuFXArchive.swift:464-498`, `GzipZipArchive.swift:100`, `298`. [read]
- [ ] Most write failures are only printed, never shown to the user — VM throughout. [read] **Partly done: import, copy, paste, delete, rename, new folder and load failures now show an alert. Export failures are still only printed.**
- [ ] Text viewer truncates at the first NUL and lays out the whole file in one `Text` — `FileInspectorSheet.swift:684-703`. [read] **Partly done: NULs no longer end the text. The whole file is still laid out in one `Text`.**
- [ ] `NuFXWriter` and `BinaryIIWriter` are dead code with the same layout errors as the readers. [run / read] **Not changed: the code is still there and unused. The README no longer claims archive writing.**
- [x] Project: stale `LIBRARY_SEARCH_PATHS` entry; README says macOS 14 but the target is 15.7; version 2.6 has no CHANGELOG entry; ~20 unused-variable warnings. [read]

## Proposed order of work

1. Section 2 one-line crash fixes (duplicate key, date encoding, range guards).
2. Section 1 corruption bugs, starting with the DOS 3.3 bitmap and the sector map.
3. Write-path guards: format checks, path-based file lookup, read-only archives, cut/paste safety.
4. NuFX, zip and Binary II readers.
5. Wrong-output items, then the smaller issues.

All five steps have been worked through (see Review). The items still unchecked above are what remains.

## Review — steps 1 to 3 (2026-10-12)

Fixed: every item in sections 1 and 2, plus the items marked done or partly done in sections 3 to 5. Nothing is committed.

What changed in behaviour:

- **Writers locate files by directory path.** `deleteFile`, `renameFile` and `setFileType` take a `parentPath`; `DiskCatalogEntry` carries its own `parentPath`.
- **The ProDOS writer validates the volume** and detects sector order from content, as the parser does. It refuses anything that is not a ProDOS volume with 39-byte entries.
- **Allocators skip anything a file already uses.** Both writers walk the directory tree first, so a block or sector that the bitmap wrongly marks free is never handed out.
- **Deleting a directory deletes its contents** and frees every block, including both forks of extended files.
- **Cut only removes what was copied.** Copy, paste and delete report per-item failures in one alert. Paste goes into the pane it was invoked on, into the directory being viewed.
- **Archive-backed and UCSD Pascal images are read-only**, with an alert explaining why.
- **A failed load leaves the pane unchanged** and shows an alert. Empty DOS 3.3 disks now open.
- **Dates use a two-digit year and the correct hour/minute order.** Disks written by earlier ProBrowse versions (year stored as year minus 1900) still display correctly; their times will show hour and minute swapped.

Verification:

- `Tests/run-tests.sh`: 176 of 176 checks pass. Covers storage-type boundaries, same-name files in different directories, DOS-ordered images, non-ProDOS images, directory loops, DOS 3.3 allocation with multi-list files, and the view model's cut, paste, delete, load and read-only paths.
- Add-then-delete round trips on copies of 878 real images from this Mac: 648 completed with every existing file byte-identical afterwards, 121 were skipped as full. Three images showed a changed file; in each the file's own block or sector pointers are out of range (`animate1.dsk`, `Looney Tunes Print Kit disk 1 side A.dsk`, `awardware1.dsk`), so the "file" overlaps free space.
- DOS 3.3 bitmap order: on 101 real disks, 95 are fully consistent under the new byte order and 24 under the old one.
- Pascal block map: 127 text pages from real UCSD disks have no stray bytes with the new map; 33 did with the old one.
- Clean Debug build succeeds.

Not verified: the app was not launched, so the alerts, the key monitor change and drag and drop were not exercised in the running UI. No real Squeeze, Teach or IIgs font samples were run after the step 1 guards.

## Review — step 4 (2026-10-13)

Fixed: the ShrinkIt, Binary II and zip readers, and opening archives from the file picker and by drop. Nothing is committed.

- **ShrinkIt:** correct signatures and thread offsets, the three LZW/2 errors and the LZW/1 chunk length, CRC checking for version 3 records, disk image size taken from the record, a 64 MB size cap, and no more quadratic copying.
- **File archives open as a read-only catalog** (ShrinkIt and Binary II), with pathnames turned into directories. Files can be copied from there onto a disk image.
- **DOS 3.3 and Pascal disks inside ShrinkIt archives** are put back in DOS sector order before parsing.
- **Zip:** entries are read from the central directory, so Finder and `ditto` archives work. Deflate output is capped at 64 MB.
- **Binary II:** 3-byte length and length-prefixed name.
- **File picker and drop** accept every format the loader handles, including `.vol`.

Verification:

- `Tests/run-tests.sh`: 196 of 196 checks pass. New checks cover both zip layouts, a spec-built Binary II archive, a hand-built stored ShrinkIt archive with a CRC failure case, and copying out of an archive pane.
- Every data thread of 432 real ShrinkIt archives on this Mac was extracted: 4,385 succeeded (version 3 threads verified by CRC), 4 failed. The failures are one truncated file and three archives that are damaged part-way through.
- Opened through the view model, 406 of 438 archives show a catalog. The other 32 extract correctly but hold a filesystem ProBrowse does not read (CP/M, copy-protected and similar).

Not verified: no real Binary II file archive with Squeeze (`.bqy`) and no real Squeeze-compressed ShrinkIt thread was available. LZW is covered by the real archives only, not by the test suite, because the suite cannot ship third-party archives. The app was still not launched.

## Review — step 5 (2026-10-13)

Fixed: the wrong-output items and most of the smaller issues. Nothing is committed.

- **DOS 3.3 entries** now carry ProDOS file types and bare contents: the address/length header is removed on read and written back on write, so BASIC detokenizes, binaries disassemble at their load address, and copies to and from ProDOS are correct. Binaries over 64 KB are refused on DOS 3.3. The lock flag is a property, not part of the name.
- **Graphics:** screen dumps are recognised by size before the MacPaint check, which now requires all 720 rows to decode. Packed pictures fall through from the Paintworks check. APF 640 mode is decoded.
- **Merlin:** the line parser was rewritten around space-separated fields.
- **Teach:** the resource map is read with the documented layout and the scanning fallback is gone.
- **AppleWorks:** records are stepped by their length byte, inverse characters map to plain ones, AWGS red and blue are no longer swapped.
- **Disassemblers:** monitor labels corrected; the 65816 mode toggle works and `XCE` follows a preceding `CLC` or `SEC`.
- **New `.2mg` images** get a 2IMG header. The create sheet validates ASCII names and no longer writes to a file the save panel did not confirm.
- **UI:** several files can be dropped at once; a drop back onto the source image is ignored; shift-click ranges stay in one directory; Delete, Cmd+O and Cmd+Shift+O work; deleting asks for confirmation; the header size no longer reads the image on every update.
- **Project and docs:** stale library search path removed; README no longer claims archive writing and states the real macOS requirement; CHANGELOG has a 2.6 entry.

Verification:

- `Tests/run-tests.sh`: 211 of 211 checks pass.
- Decoders were run over files from the ProDOS images on this Mac: 509 AppleWorks word processor files (507 decode, 2 are not valid AWP), 111 Merlin sources (4 of 31,247 lines look mis-split), 46 Teach documents with a resource fork (21 now show more than one style), and about 2,000 pictures. Two 640-mode pictures were rendered to PNG and looked at.
- The add/delete round trips on real images give the same result as after step 3 (648 clean).
- Clean Debug build succeeds with two warnings left, both in code this work did not touch.

Not verified: the app was never launched. The Teach and AppleWorks layout change, the key handling, drag and drop and the confirmation alert compile but were not exercised in the running UI. The AppleWorks record-stepping and AWGS fixes rest on the format description; only one AWGS file was available.

Left open on purpose: the Disk Image Inspector is still unreachable, the key monitor is still an event monitor rather than menu commands, directories cannot grow past one block, and 65C02 opcodes are not decoded.


## Review — UI test in the running app (2026-10-13)

The Debug build was launched and driven by hand on throwaway copies of images.

Worked as intended:

- Cmd+O and Cmd+Shift+O open the left and right pickers; the picker offers `.shk` and the other archive types.
- Cut two-step: a 300 KB file cut to a 140K disk stays on the source and an alert names it; a small file moves, and both panes refresh.
- Copying a folder with Cmd+C / Cmd+V recreates it with its contents in the other pane.
- Delete key asks for confirmation; deleting `/GAMES/README` leaves `/README` alone. The images on disk were checked afterwards.
- New Folder inside a subdirectory creates it there and the pane stays in that directory.
- A ShrinkIt archive opens, and Delete on it is refused with the read-only alert.
- A Teach document shows its styles on normally wrapped lines; a DOS 3.3 Applesoft program detokenizes; DOS 3.3 names with spaces, lock icons and load addresses display; a 640-mode picture renders.

Found and fixed during the test:

- Clicking empty space in a pane did not make it active, so Cmd+V went to the wrong pane. The whole pane now takes the click (`DiskBrowserPane.swift`).
- The picture inspector labelled every Super Hi-Res picture "320x200". It now shows the decoded size. This label change was built but not looked at again in the app.

Not exercised: drag and drop between panes, dropping files from Finder, the Create Image sheet, Merlin and AppleWorks viewers in the app, and Cmd-click multi-selection (the automated click did not deliver the modifier, so this says nothing about real use).

## Review — sandbox test (2026-10-13)

An ad-hoc signed build with the App Sandbox entitlements was run (the process was confirmed sandboxed) and driven by hand on throwaway images.

Found and fixed:

- **Every write failed** with "Could not read disk image": access to the picked file was given back right after loading. The pane now holds that access for as long as the image is open (`DiskPaneViewModel.loadDiskImage`).
- **Export did nothing and said nothing.** Writing to Downloads needs its own entitlement; `com.apple.security.files.downloads.read-write` was added to `ProBrowse.entitlements`, and export failures now show an alert.
- **Exported text files were named `.bin`.** The extension table used DOS 3.3 type codes; it now uses ProDOS types.

Worked in the sandbox after the fixes: opening images, cut/paste between two images, copying a DOS 3.3 file to ProDOS, New Folder, Delete with confirmation, Export to Downloads, and creating a new `.2mg` through the save panel.

Not exercised in the sandbox: drag and drop between panes and from Finder, opening an archive, and a build signed with the real team identity (the test used ad-hoc signing).
