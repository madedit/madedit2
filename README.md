# MadEdit2

MadEdit2 is a fast text and hex editor for very large files. It opens multi gigabyte files instantly, edits them in place, and runs natively on Windows, macOS and Linux.

It is free software. Prebuilt binaries are provided on the [Releases](https://github.com/madedit/madedit2/releases) page.

## Features

* Opens files of any size instantly: nothing is read up front, only what you scroll past.
* Full editing of huge files with unlimited undo and redo, saved back atomically so a crash never leaves a half written file.
* Text, column (rectangular block) and hex modes; the hex view shows a decoded text column for the file's encoding.
* Syntax highlighting for about 50 languages via WASM grammar plugins, with incremental reparsing while you type.
* Code folding and a document outline for the highlighted languages.
* 39 text encodings with automatic detection, plus conversion between encodings and line ending styles.
* Find and replace with regular expressions, whole word and find in selection, across a single file or a whole folder tree.
* Multiple cursors, expand and shrink selection, smart Home, auto closing brackets and quotes.
* Bookmarks, go to line and column, navigation history (go back and forward), bracket matching.
* Macros: record, replay, repeat until end of file, save and manage.
* User scripts in JavaScript or Lua that transform the document line by line or as a whole.
* Word completion from the document and the language's keywords.
* Quick open by fuzzy file name, recent files list, file explorer sidebar with drag and drop.
* Run external commands with placeholders for the current file and see their output in a panel.
* Soft wrap by window width or column count, whitespace and indent guide display, quick font zoom.
* Right-to-left layout for Arabic and Hebrew, detected automatically or switched by hand.
* Familiar keyboard shortcuts out of the box, plus a Vim mode, all customizable in a shortcut editor.

## Download

Prebuilt packages for Windows, macOS and Linux are attached to every release on the [Releases](https://github.com/madedit/madedit2/releases) page:

* **Windows**: `madedit2-<version>-windows-x64.zip` — unzip anywhere and run `madedit2.exe`; settings live next to the executable (portable).
* **macOS**: `madedit2-<version>.dmg` — signed and notarized; drag the app to Applications.
* **Linux**: `madedit2-<version>-linux-x64.tar.gz` — built on AlmaLinux 9 (glibc 2.34), so it runs on RHEL/Rocky/Alma 9+, Ubuntu 22.04+, Debian 12+, Fedora and other distributions with glibc 2.34 or newer.

## Support the project

If MadEdit2 is useful to you, you can support its development through the Help menu (Support Development) inside the app, or via:

* [Buy Me a Bubble Tea](https://madedit.bobaboba.me/)
* [Ko-fi](https://ko-fi.com/madedit)
* [PayPal](https://paypal.me/madedit)
