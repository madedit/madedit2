/// Editor action interface: commands drive the editor through it. The view
/// provides the concrete implementation; tests can use a fake that records
/// calls. Keeping it abstract means the keymap only references command
/// names, decoupled from the implementation.
abstract class EditorActions {
  void scrollLines(int n); // positive = down, negative = up
  void scrollPages(int n);
  void scrollHalfPages(int n);
  void toTop();
  void toBottom();
  void gotoLine(int oneBased); // needs the line index
  void setMode(String mode); // modal switch

  // ── Caret (phase 3). dir: -1/+1; select: extend the selection (false collapses) ──
  void caretHorizontal(int dir, int count, bool select); // left/right one character
  void caretVertical(int dir, int count, bool select); // up/down one line (keeps the goal column)
  void caretLineEdge(int dir, bool select); // line start (-1) / line end (+1)
  void caretWord(int dir, int count, bool select); // previous (-1) / next (+1) word
  void deleteWord(int dir, int count); // delete to the previous (-1) / next (+1) word boundary
  void selectLine(); // select the whole line (repeat to extend line by line)
  void insertLine(int dir); // insert a new line above (-1) / below (+1) and move to it
  void insertNewlinePlain(); // shift+enter: a bare newline, no auto-indent
  void caretDocEdge(int dir, bool select); // document start (-1) / end (+1)
  void caretPage(int dir, bool select); // page up (-1) / down (+1), viewport scrolls along
  void copySelection(); // copy the selection to the clipboard
  void pasteClipboard(); // paste from the clipboard (replaces the selection)
  void cutSelection(); // cut: copy the selection, then delete it
  void selectAll(); // select all (0..end of document)

  // ── Search ──
  void openSearch(); // open the search bar (focus in the input)
  void openReplace(); // open the search bar plus the replace row
  void findNext(); // find the next match forward
  void findPrev(); // find the previous match backward
  void findInFiles(); // ctrl+shift+f: find in files (shell panel)

  // ── Multi-cursor ──
  void addCursorVertical(int dir); // ctrl+alt+up(-1)/down(+1): add a cursor
  void selectAllOccurrences(); // ctrl+shift+l: a cursor on every occurrence
  void addNextOccurrence(); // ctrl+alt+d: add a cursor on the next occurrence
  void clearCursors(); // escape: back to the primary cursor
  void cursorsAtLineEnds(); // shift+alt+i: a cursor at the end of each selected line
  void expandSelection(); // shift+alt+right: word → brackets → line → document
  void shrinkSelection(); // shift+alt+left: back one expand step

  // ── Macro ──
  void macroRecordToggle(); // ctrl+shift+r: start / stop recording (shell)
  void macroPlay(); // ctrl+shift+e: replay the last recorded macro (shell)
  void toggleExplorer(); // ctrl+b: file explorer sidebar (shell)
  void toggleOutline(); // ctrl+shift+o: document outline sidebar (shell)
  void toggleWordWrap(); // alt+z: soft wrap on / off (shell, global setting)
  void openKeymapEditor(); // ctrl+k ctrl+s: the shortcut editor (shell)

  // ── Dynamic-menu items as keyable commands (args carry the name) ──
  void runScriptNamed(String name); // script.run {name}
  void setSyntaxNamed(String mode); // syntax.set {mode}: auto/plain/<lang>
  void setEncodingNamed(String name); // encoding.set {name}
  void runMacroNamed(String name); // macro.run {name} (shell)

  // ── Code folding (tree-sitter sessions only) ──
  void foldAtCaret(); // ctrl+shift+[: fold the innermost region at the caret
  void unfoldAtCaret(); // ctrl+shift+]: expand the region at the caret
  void foldAll(); // ctrl+k ctrl+0
  void unfoldAll(); // ctrl+k ctrl+j
  void triggerCompletion(); // ctrl+space: word completion popup
  void printDocument(); // ctrl+p: print dialog (shell)
  void runExternalPrompt(); // ctrl+f5: Run… dialog (shell)
  void runExternalNamed(String name); // run.command {name} (shell)
  void clipboardHistory(); // ctrl+shift+v: pick from the clipboard history (shell)
  void columnEditor(); // alt+c: column editor dialog (shell)

  void matchBracket(); // ctrl+m: jump to the matching bracket

  // ── Navigation history (VS Code Go Back / Forward) ──
  void navBack(); // alt+left (Windows/Linux), control+- (macOS)
  void navForward(); // alt+right / control+shift+-
  void navLastEdit(); // ctrl+k ctrl+q: where the last edit happened
  void toggleFoldAtCaret(); // ctrl+k ctrl+l

  /// Shell-level menu actions bound to keys (save all, close all, quick
  /// open, …): dispatched to the shell's menu handler by name.
  void menuAction(String action);

  void zoomFont(
    int steps,
  ); // ctrl+= / ctrl+- / ctrl+0 (0 = reset): quick font zoom

  // ── Bookmarks ──
  void toggleBookmark(); // ctrl+f2: add/remove a bookmark on the current line
  void nextBookmark(); // f2: jump to the next bookmark (wraps)
  void prevBookmark(); // shift+f2: jump to the previous bookmark (wraps)
  void clearBookmarks(); // clear all bookmarks in this file

  // ── Editing (phase 4) ──
  void undo();
  void redo();
  void deleteLine(); // ctrl+d: delete the logical line at the caret (including its newline)
  void duplicateLine(int dir); // duplicate the current line: dir=+1 caret goes to the
  // lower copy (ctrl+shift+d / shift+alt+down), -1 caret stays on the upper copy
  // (shift+alt+up); the inserted content is identical
  void moveLine(int dir); // alt+up(-1)/alt+down(+1): swap with the adjacent line
  void toggleComment(); // ctrl+/: toggle the line-comment prefix on the current line
  void toggleBlockComment(); // ctrl+shift+/: wrap/unwrap the selection (or current line) in /* */
  void indentLines(int dir); // tab/shift+tab: indent (+1) / outdent (-1) the lines covered by the selection
  void transformLines(
    String op,
  ); // Edit → Lines: upper/lower/joinLines/sortAsc/… (line_ops.dart)

  // ── Saving (phase 5) ──
  void save();
  void saveAs(); // ctrl+shift+s: save as
  void reloadFile(); // File → Reload File: reopen from disk (confirms if modified)

  // ── Tabs ──
  void newTab(); // ctrl+n: open a new untitled tab
  void newWindow(); // ctrl+shift+n: open a new window (--new-window child process)
  void closeWindow(); // ctrl+shift+w: close the window (goes through the onWindowClose confirmation flow)
  void openFileDialog(); // ctrl+o: pick a file and open it in a new tab (already open → jump to its tab; handled by the shell)
  void gotoLinePrompt(); // ctrl+g: open the go-to-line input row
  void closeTab(); // close this pane (the layout belongs to the shell; forwarded via a controller hook)
  void nextTab(); // ctrl+tab: switch to the next tab (cycles in layout order)
  void prevTab(); // ctrl+shift+tab: switch to the previous tab
  void gotoTab(int n); // alt+1..9: jump to the n-th tab (1-based, layout order)
  void reopenClosedTab(); // ctrl+shift+t: reopen the most recently closed tab
  void commandPalette(); // ctrl+shift+p: command palette (flattened menu tree; handled by the shell)
}

typedef CommandHandler =
    void Function(EditorActions ed, Map<String, Object?>? args, int count);

/// Named command registry. A keymap's command string maps to a handler here.
class CommandRegistry {
  final Map<String, CommandHandler> _handlers = {};

  /// Every registered command name (keymap editor listing).
  Iterable<String> get names => _handlers.keys;

  void register(String name, CommandHandler handler) =>
      _handlers[name] = handler;
  CommandHandler? lookup(String name) => _handlers[name];

  void dispatch(
    String name,
    EditorActions ed,
    Map<String, Object?>? args,
    int count,
  ) {
    _handlers[name]?.call(ed, args, count);
  }

  /// Registers the editor's default command set (scrolling / jumping / modes).
  /// All presets share these names.
  static CommandRegistry defaults() {
    final r = CommandRegistry();
    r.register('noop', (ed, a, n) {});
    r.register('view.lineDown', (ed, a, n) => ed.scrollLines(n));
    r.register('view.lineUp', (ed, a, n) => ed.scrollLines(-n));
    r.register('view.pageDown', (ed, a, n) => ed.scrollPages(n));
    r.register('view.pageUp', (ed, a, n) => ed.scrollPages(-n));
    r.register('view.halfPageDown', (ed, a, n) => ed.scrollHalfPages(n));
    r.register('view.halfPageUp', (ed, a, n) => ed.scrollHalfPages(-n));
    r.register('view.top', (ed, a, n) => ed.toTop());
    r.register('view.bottom', (ed, a, n) => ed.toBottom());
    r.register('vim.enterInsert', (ed, a, n) => ed.setMode('insert'));
    r.register('vim.enterNormal', (ed, a, n) => ed.setMode('normal'));
    r.register('vim.enterVisual', (ed, a, n) => ed.setMode('visual'));

    // ── Caret movement (including the *Select extend-selection variants) ──
    r.register('caret.left', (ed, a, n) => ed.caretHorizontal(-1, n, false));
    r.register(
      'caret.leftSelect',
      (ed, a, n) => ed.caretHorizontal(-1, n, true),
    );
    r.register('caret.right', (ed, a, n) => ed.caretHorizontal(1, n, false));
    r.register(
      'caret.rightSelect',
      (ed, a, n) => ed.caretHorizontal(1, n, true),
    );
    r.register('caret.up', (ed, a, n) => ed.caretVertical(-1, n, false));
    r.register('caret.upSelect', (ed, a, n) => ed.caretVertical(-1, n, true));
    r.register('caret.down', (ed, a, n) => ed.caretVertical(1, n, false));
    r.register('caret.downSelect', (ed, a, n) => ed.caretVertical(1, n, true));
    r.register('caret.wordLeft', (ed, a, n) => ed.caretWord(-1, n, false));
    r.register('caret.wordLeftSelect', (ed, a, n) => ed.caretWord(-1, n, true));
    r.register('caret.wordRight', (ed, a, n) => ed.caretWord(1, n, false));
    r.register('caret.wordRightSelect', (ed, a, n) => ed.caretWord(1, n, true));
    r.register('edit.deleteWordLeft', (ed, a, n) => ed.deleteWord(-1, n));
    r.register('edit.deleteWordRight', (ed, a, n) => ed.deleteWord(1, n));
    r.register('edit.selectLine', (ed, a, n) => ed.selectLine());
    r.register('edit.insertLineBelow', (ed, a, n) => ed.insertLine(1));
    r.register('edit.insertLineAbove', (ed, a, n) => ed.insertLine(-1));
    r.register('edit.newlinePlain', (ed, a, n) => ed.insertNewlinePlain());
    r.register('caret.lineStart', (ed, a, n) => ed.caretLineEdge(-1, false));
    r.register(
      'caret.lineStartSelect',
      (ed, a, n) => ed.caretLineEdge(-1, true),
    );
    r.register('caret.lineEnd', (ed, a, n) => ed.caretLineEdge(1, false));
    r.register('caret.lineEndSelect', (ed, a, n) => ed.caretLineEdge(1, true));
    r.register('caret.pageUp', (ed, a, n) => ed.caretPage(-1, false));
    r.register('caret.pageUpSelect', (ed, a, n) => ed.caretPage(-1, true));
    r.register('caret.pageDown', (ed, a, n) => ed.caretPage(1, false));
    r.register('caret.pageDownSelect', (ed, a, n) => ed.caretPage(1, true));
    r.register('caret.docStart', (ed, a, n) => ed.caretDocEdge(-1, false));
    r.register('caret.docStartSelect', (ed, a, n) => ed.caretDocEdge(-1, true));
    r.register('caret.docEnd', (ed, a, n) => ed.caretDocEdge(1, false));
    r.register('caret.docEndSelect', (ed, a, n) => ed.caretDocEdge(1, true));
    r.register('edit.copy', (ed, a, n) => ed.copySelection());
    r.register('edit.paste', (ed, a, n) => ed.pasteClipboard());
    r.register('edit.cut', (ed, a, n) => ed.cutSelection());
    r.register('edit.selectAll', (ed, a, n) => ed.selectAll());
    r.register('search.find', (ed, a, n) => ed.openSearch());
    r.register('search.replace', (ed, a, n) => ed.openReplace());
    r.register('search.findNext', (ed, a, n) => ed.findNext());
    r.register('search.findPrev', (ed, a, n) => ed.findPrev());
    r.register('search.findInFiles', (ed, a, n) => ed.findInFiles());
    r.register('caret.matchBracket', (ed, a, n) => ed.matchBracket());
    r.register('cursor.addAbove', (ed, a, n) => ed.addCursorVertical(-1));
    r.register('cursor.addBelow', (ed, a, n) => ed.addCursorVertical(1));
    r.register(
      'cursor.selectAllOccurrences',
      (ed, a, n) => ed.selectAllOccurrences(),
    );
    r.register(
      'cursor.addNextOccurrence',
      (ed, a, n) => ed.addNextOccurrence(),
    );
    r.register('cursor.clear', (ed, a, n) => ed.clearCursors());
    r.register('cursor.lineEnds', (ed, a, n) => ed.cursorsAtLineEnds());
    r.register('select.expand', (ed, a, n) => ed.expandSelection());
    r.register('select.shrink', (ed, a, n) => ed.shrinkSelection());
    r.register('macro.record', (ed, a, n) => ed.macroRecordToggle());
    r.register('macro.play', (ed, a, n) => ed.macroPlay());
    r.register('view.explorer', (ed, a, n) => ed.toggleExplorer());
    r.register('view.outline', (ed, a, n) => ed.toggleOutline());
    r.register('wrap.toggle', (ed, a, n) => ed.toggleWordWrap());
    r.register('keymap.editor', (ed, a, n) => ed.openKeymapEditor());
    String? nameArg(Map<String, Object?>? a, String key) {
      final v = a?[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    r.register('script.run', (ed, a, n) {
      final v = nameArg(a, 'name');
      if (v != null) ed.runScriptNamed(v);
    });
    r.register('syntax.set', (ed, a, n) {
      final v = nameArg(a, 'mode');
      if (v != null) ed.setSyntaxNamed(v);
    });
    r.register('encoding.set', (ed, a, n) {
      final v = nameArg(a, 'name');
      if (v != null) ed.setEncodingNamed(v);
    });
    r.register('macro.run', (ed, a, n) {
      final v = nameArg(a, 'name');
      if (v != null) ed.runMacroNamed(v);
    });
    r.register('fold.fold', (ed, a, n) => ed.foldAtCaret());
    r.register('fold.unfold', (ed, a, n) => ed.unfoldAtCaret());
    r.register('fold.all', (ed, a, n) => ed.foldAll());
    r.register('fold.unfoldAll', (ed, a, n) => ed.unfoldAll());
    r.register('edit.complete', (ed, a, n) => ed.triggerCompletion());
    r.register('file.print', (ed, a, n) => ed.printDocument());
    r.register('nav.back', (ed, a, n) => ed.navBack());
    r.register('nav.forward', (ed, a, n) => ed.navForward());
    r.register('nav.lastEdit', (ed, a, n) => ed.navLastEdit());
    r.register('fold.toggle', (ed, a, n) => ed.toggleFoldAtCaret());
    // Shell actions reachable from the keymap (the shell's _onMenuAction
    // handles the same names as the menu JSON).
    for (final action in const [
      'file.saveAll',
      'file.closeAll',
      'file.quickOpen',
      'file.openRecent',
      'search.replaceInFiles',
      'syntax.picker',
      'view.splitRight',
    ]) {
      r.register(action, (ed, a, n) => ed.menuAction(action));
    }
    r.register('run.prompt', (ed, a, n) => ed.runExternalPrompt());
    r.register('run.command', (ed, a, n) {
      final v = nameArg(a, 'name');
      if (v != null) ed.runExternalNamed(v);
    });
    r.register('edit.clipboardHistory', (ed, a, n) => ed.clipboardHistory());
    r.register('edit.columnEditor', (ed, a, n) => ed.columnEditor());
    r.register('bookmark.toggle', (ed, a, n) => ed.toggleBookmark());
    r.register('bookmark.next', (ed, a, n) => ed.nextBookmark());
    r.register('bookmark.prev', (ed, a, n) => ed.prevBookmark());
    r.register('bookmark.clearAll', (ed, a, n) => ed.clearBookmarks());
    r.register('edit.undo', (ed, a, n) => ed.undo());
    r.register('edit.redo', (ed, a, n) => ed.redo());
    r.register('edit.deleteLine', (ed, a, n) => ed.deleteLine());
    r.register('edit.duplicateLine', (ed, a, n) => ed.duplicateLine(1));
    r.register('edit.copyLineUp', (ed, a, n) => ed.duplicateLine(-1));
    r.register('edit.copyLineDown', (ed, a, n) => ed.duplicateLine(1));
    r.register('edit.moveLineUp', (ed, a, n) => ed.moveLine(-1));
    r.register('edit.moveLineDown', (ed, a, n) => ed.moveLine(1));
    r.register('edit.indent', (ed, a, n) => ed.indentLines(1));
    r.register('edit.outdent', (ed, a, n) => ed.indentLines(-1));
    for (final op in [
      'upper',
      'lower',
      'joinLines',
      'sortAsc',
      'sortDesc',
      'dedupeLines',
      'removeEmptyLines',
      'trimTrailing',
      'reverseLines',
    ]) {
      r.register('edit.$op', (ed, a, n) => ed.transformLines(op));
    }
    r.register('edit.toggleComment', (ed, a, n) => ed.toggleComment());
    r.register(
      'edit.toggleBlockComment',
      (ed, a, n) => ed.toggleBlockComment(),
    );
    r.register('edit.save', (ed, a, n) => ed.save());
    r.register('file.saveAs', (ed, a, n) => ed.saveAs());
    r.register('file.reload', (ed, a, n) => ed.reloadFile());
    r.register('file.new', (ed, a, n) => ed.newTab());
    r.register('file.newWindow', (ed, a, n) => ed.newWindow());
    r.register('file.closeWindow', (ed, a, n) => ed.closeWindow());
    r.register('file.open', (ed, a, n) => ed.openFileDialog());
    r.register('search.gotoLine', (ed, a, n) => ed.gotoLinePrompt());
    r.register('file.closeTab', (ed, a, n) => ed.closeTab());
    r.register('view.nextTab', (ed, a, n) => ed.nextTab());
    r.register('view.prevTab', (ed, a, n) => ed.prevTab());
    r.register('file.reopenTab', (ed, a, n) => ed.reopenClosedTab());
    r.register('view.commandPalette', (ed, a, n) => ed.commandPalette());
    r.register('view.zoomIn', (ed, a, n) => ed.zoomFont(n));
    r.register('view.zoomOut', (ed, a, n) => ed.zoomFont(-n));
    r.register('view.zoomReset', (ed, a, n) => ed.zoomFont(0));
    r.register('view.gotoTab', (ed, a, n) {
      final t = a?['n'];
      if (t is int && t >= 1) ed.gotoTab(t);
    });
    return r;
  }
}
