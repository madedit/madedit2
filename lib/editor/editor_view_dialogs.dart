part of 'editor_view.dart';

// A user-script failure inside the transform callback; toString is the bare
// message (a StateError would prefix the toast with "Bad state:").
class _ScriptRunError implements Exception {
  _ScriptRunError(this.message);
  final String message;
  @override
  String toString() => message;
}

// Word-count dialog: streams the byte range through StatsAccumulator with a
// progress bar; counting stops when the dialog is dismissed. Chunk edges are
// re-aligned to character boundaries (the trailing, possibly cut char of
// each chunk is dropped and re-read next round, surrogate pairs included).
/// Modal "working…" dialog (indeterminate) for a long run such as a user
/// script; closes itself when [done] completes and cannot be dismissed.
class _BusyDialog extends StatefulWidget {
  const _BusyDialog({
    required this.title,
    required this.body,
    required this.done,
    this.onCancel,
  });
  final String title;
  final String body;
  final Future<void> done;

  /// When given, a Cancel button asks the work to stop (the dialog still
  /// closes only once [done] completes).
  final VoidCallback? onCancel;

  @override
  State<_BusyDialog> createState() => _BusyDialogState();
}

class _BusyDialogState extends State<_BusyDialog> {
  @override
  void initState() {
    super.initState();
    widget.done.whenComplete(() {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.body),
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ),
      ),
      actions: widget.onCancel == null
          ? null
          : [
              TextButton(
                onPressed: widget.onCancel,
                child: Text(AppLocalizations.of(context).tr('common_cancel')),
              ),
            ],
    ),
  );
}

/// Modal progress shown while the first edit of a big file waits for the line
/// index (see _EditorViewState._onIndexWait). Closes itself when [done]
/// completes; cannot be dismissed — the edit is already committed to waiting.
class _IndexWaitDialog extends StatefulWidget {
  const _IndexWaitDialog({required this.doc, required this.done});
  final Document doc;
  final Future<void> done;

  @override
  State<_IndexWaitDialog> createState() => _IndexWaitDialogState();
}

class _IndexWaitDialogState extends State<_IndexWaitDialog> {
  StreamSubscription<IndexProgress>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.doc.progress.listen((_) {
      if (mounted) setState(() {});
    });
    widget.done.whenComplete(() {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pct = (widget.doc.fractionIndexed * 100).floor();
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(l10n.tr('index_wait_title')),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.tr('index_wait_body')),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: widget.doc.fractionIndexed),
              const SizedBox(height: 8),
              Text(l10n.trf('status_indexing', [pct])),
            ],
          ),
        ),
      ),
    );
  }
}

class _WordCountDialog extends StatefulWidget {
  const _WordCountDialog({
    required this.doc,
    required this.start,
    required this.end,
    required this.selection,
  });

  final Document doc;
  final int start;
  final int end;
  final bool selection;

  @override
  State<_WordCountDialog> createState() => _WordCountDialogState();
}

class _WordCountDialogState extends State<_WordCountDialog> {
  TextStats? _stats;
  double _progress = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _run() async {
    final acc = StatsAccumulator();
    final end = widget.end;
    final total = end - widget.start;
    var pos = widget.start;
    while (pos < end) {
      if (_disposed) return;
      final readLen = (end - pos) < (1 << 20) ? (end - pos) : (1 << 20);
      final d = await widget.doc.readRangeDecoded(pos, readLen);
      final text = d.text;
      var nextPos = pos + readLen;
      if (pos + readLen < end && text.length > 1) {
        // Drop the final (possibly cut) char; a low surrogate at the end
        // means the pair starts one unit earlier.
        var cut = text.length - 1;
        final cu = text.codeUnitAt(cut);
        if (cu >= 0xDC00 && cu <= 0xDFFF && cut > 0) cut--;
        acc.feed(text.substring(0, cut));
        final aligned = pos + d.byteForCodeUnit(cut);
        nextPos = aligned > pos ? aligned : pos + readLen;
      } else {
        acc.feed(text);
      }
      pos = nextPos;
      if (mounted && total > 0) {
        setState(() => _progress = (pos - widget.start) / total);
      }
    }
    if (mounted) setState(() => _stats = acc.finish(total));
  }

  static String _n(int v) {
    final s = '$v';
    final sb = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) sb.write(',');
      sb.write(s[i]);
    }
    return sb.toString();
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [Text(label), const SizedBox(width: 32), Text(value)],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final st = _stats;
    return AlertDialog(
      title: Text(l10n.tr('wc_title')),
      content: ResizableDialogBox(
        id: 'wordCount',
        initialWidth: 320,
        child: st == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: _progress),
                  const SizedBox(height: 8),
                  Text('${(_progress * 100).floor()}%'),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.tr(widget.selection ? 'wc_scope_sel' : 'wc_scope_all'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  _row(l10n.tr('wc_lines'), _n(st.lines)),
                  _row(l10n.tr('wc_chars'), _n(st.chars)),
                  _row(l10n.tr('wc_chars_no_ws'), _n(st.charsNoWs)),
                  _row(l10n.tr('wc_words'), _n(st.words)),
                  _row(l10n.tr('wc_cjk'), _n(st.cjk)),
                  _row(l10n.tr('wc_bytes'), _n(st.bytes)),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.tr('common_close')),
        ),
      ],
    );
  }
}

// Checksum dialog: hashes the byte range with every supported algorithm in
// one streaming pass. The range is the selection when there is one, otherwise
// the whole document. Computing stops when the dialog is dismissed.
class _ChecksumDialog extends StatefulWidget {
  const _ChecksumDialog({
    required this.doc,
    required this.start,
    required this.end,
    required this.selection,
  });

  final Document doc;
  final int start;
  final int end;
  final bool selection;

  @override
  State<_ChecksumDialog> createState() => _ChecksumDialogState();
}

class _ChecksumDialogState extends State<_ChecksumDialog> {
  static const int _chunk = 1 << 20;

  bool _cancelled = false;
  double _progress = 0;
  String? _error;
  List<ChecksumResult>? _results;

  @override
  void initState() {
    super.initState();
    _compute();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _compute() async {
    final total = widget.end - widget.start;
    final accs = checksumAlgorithms.map(ChecksumAccumulator.new).toList();
    var pos = widget.start;
    try {
      while (pos < widget.end && !_cancelled) {
        final len = (widget.end - pos) > _chunk ? _chunk : widget.end - pos;
        final bytes = await widget.doc.readRangeBytes(pos, len);
        if (_cancelled) return;
        for (final acc in accs) {
          acc.add(bytes);
        }
        pos += len;
        if (mounted && total > 0) {
          setState(() => _progress = (pos - widget.start) / total);
        }
      }
      if (_cancelled) return;
      final results = accs.map((a) => a.close()).toList();
      if (mounted) setState(() => _results = results);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _copyAllText() =>
      _results?.map((r) => '${r.algorithm}: ${r.hex}').join('\n') ?? '';

  Future<void> _copy(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  Widget _row(ChecksumResult r) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              r.algorithm,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SelectableText(
              r.hex,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          IconButton(
            tooltip: l10n.tr('checksum_copy'),
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () => _copy(r.hex),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final results = _results;
    final error = _error;
    return AlertDialog(
      title: Text(l10n.tr('checksum_title')),
      content: ResizableDialogBox(
        id: 'checksum',
        initialWidth: 560,
        initialHeight: 360,
        child: error != null
            ? Text(l10n.trf('checksum_failed', [error]))
            : results == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: _progress),
                  const SizedBox(height: 8),
                  Text('${l10n.tr('checksum_computing')} ${(_progress * 100).floor()}%'),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.tr(widget.selection ? 'checksum_scope_sel' : 'checksum_scope_all'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    l10n.trf('checksum_size_fmt', [
                      (widget.end - widget.start).toString(),
                    ]),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.separated(
                      itemCount: results.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) => _row(results[i]),
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: results == null ? null : () => _copy(_copyAllText()),
          child: Text(l10n.tr('checksum_copy_all')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.tr('common_close')),
        ),
      ],
    );
  }
}

// Copy-bytes dialog: reads the byte range (the selection when there is one,
// otherwise the whole document) and offers it as a C initializer list or a
// space-separated hex string. The range is loaded once with a progress bar and
// previewed truncated; the copy button formats the full range. Ranges larger
// than copyBytesMaxBytes are refused rather than building a giant string.
class _CopyBytesDialog extends StatefulWidget {
  const _CopyBytesDialog({
    required this.doc,
    required this.start,
    required this.end,
    required this.selection,
  });

  final Document doc;
  final int start;
  final int end;
  final bool selection;

  @override
  State<_CopyBytesDialog> createState() => _CopyBytesDialogState();
}

class _CopyBytesDialogState extends State<_CopyBytesDialog> {
  static const int _chunk = 1 << 20;
  static const int _previewBytes = 2048;

  bool _cancelled = false;
  double _progress = 0;
  String? _error;
  Uint8List? _bytes;
  bool _tooLarge = false;
  bool _cArray = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _load() async {
    final total = widget.end - widget.start;
    if (total > copyBytesMaxBytes) {
      if (mounted) setState(() => _tooLarge = true);
      return;
    }
    final out = Uint8List(total);
    var pos = widget.start;
    var filled = 0;
    try {
      while (pos < widget.end && !_cancelled) {
        final len = (widget.end - pos) > _chunk ? _chunk : widget.end - pos;
        final bytes = await widget.doc.readRangeBytes(pos, len);
        if (_cancelled) return;
        out.setRange(filled, filled + bytes.length, bytes);
        filled += bytes.length;
        pos += len;
        if (mounted && total > 0) {
          setState(() => _progress = (pos - widget.start) / total);
        }
      }
      if (_cancelled) return;
      if (mounted) setState(() => _bytes = out);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _format(List<int> bytes) =>
      _cArray ? bytesToCArray(bytes) : bytesToHexString(bytes);

  // Preview only the first bytes: a 16 MB range would otherwise drop a
  // multi-megabyte string into a SelectableText and stall the frame.
  String _preview() {
    final bytes = _bytes;
    if (bytes == null) return '';
    if (bytes.length <= _previewBytes) return _format(bytes);
    return '${_format(bytes.sublist(0, _previewBytes))}\n\u2026';
  }

  Future<void> _copy() async {
    final bytes = _bytes;
    if (bytes == null) return;
    await Clipboard.setData(ClipboardData(text: _format(bytes)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bytes = _bytes;
    final error = _error;
    final Widget body;
    if (_tooLarge) {
      body = Text(l10n.trf('copybytes_too_large', [copyBytesMaxBytes >> 20]));
    } else if (error != null) {
      body = Text(l10n.trf('copybytes_failed', [error]));
    } else if (bytes == null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
          Text('${l10n.tr('checksum_computing')} ${(_progress * 100).floor()}%'),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.tr(widget.selection ? 'checksum_scope_sel' : 'checksum_scope_all'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Text(
            l10n.trf('checksum_size_fmt', [bytes.length.toString()]),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                value: true,
                label: Text(l10n.tr('copybytes_fmt_c')),
              ),
              ButtonSegment(
                value: false,
                label: Text(l10n.tr('copybytes_fmt_hex')),
              ),
            ],
            selected: {_cArray},
            onSelectionChanged: (s) => setState(() => _cArray = s.first),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _preview(),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return AlertDialog(
      title: Text(l10n.tr('copybytes_title')),
      content: ResizableDialogBox(
        id: 'copybytes',
        initialWidth: 560,
        initialHeight: 360,
        child: body,
      ),
      actions: [
        TextButton(
          onPressed: bytes == null ? null : _copy,
          child: Text(l10n.tr('checksum_copy')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.tr('common_close')),
        ),
      ],
    );
  }
}

/// State of the word-completion popup (see _EditorViewState._completion).
