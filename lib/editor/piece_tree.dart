// Piece-tree: an editable document represented as a balanced binary tree
// (augmented AVL).
//
// Design points (built for GB-scale file editing):
//   - Document = a sequence of pieces; each piece points at a byte range of
//     some buffer:
//     buffer 0 = original (the file on disk, read-only, read through LargeFile windows);
//     buffer 1 = add (append-only new input held in memory).
//   - On open the whole document is a single piece: (original, 0, fileSize).
//     Insert/delete only split pieces; the original file is untouched and never
//     loaded whole → memory ∝ amount of editing, not file size.
//   - Every node caches subtree aggregates: subBytes (byte count) and subLF
//     (newline count) → locating by byte offset or line number is O(log n).
//
// This file is a **pure data structure, fully synchronous, no IO**: it never
// reads buffer contents, it only moves/splits pieces and maintains aggregates.
// Computations that need disk reads, such as "how many newlines are in the
// left half when splitting an original piece", are done up front by the layer
// above (Document) and passed in as lfLeft; the tree is only responsible for
// structural correctness and consistent aggregates.

/// Immutable description of a piece (returned to the caller on remove/re-insert).
class PieceRef {
  const PieceRef(this.buffer, this.start, this.length, this.lf);

  final int buffer; // 0 = original, 1 = add
  final int start; // start byte within that buffer
  final int length; // byte length
  final int lf; // newline count within this piece
}

/// Location result: which piece the offset falls in and where, plus the bytes /
/// newlines accumulated before it.
class PieceLoc {
  const PieceLoc({
    required this.buffer,
    required this.bufStart,
    required this.within,
    required this.pieceLen,
    required this.pieceLF,
    required this.lfBefore,
    required this.pieceStart,
  });

  final int buffer;
  final int bufStart; // start of this piece within its buffer
  final int within; // displacement of offset inside this piece (0 = exactly at the piece start)
  final int pieceLen;
  final int pieceLF;
  final int lfBefore; // newlines accumulated before (excluding) this piece
  final int pieceStart; // starting byte offset of this piece in the document
}

class _Node {
  _Node(this.buffer, this.start, this.length, this.lf);

  int buffer;
  int start;
  int length;
  int lf;

  _Node? left;
  _Node? right;
  _Node? parent;
  int height = 1;
  int subBytes = 0; // total bytes of the subtree (including self)
  int subLF = 0; // total newlines of the subtree (including self)
}

class PieceTree {
  _Node? _root;

  /// Build the whole document as a single original piece ([length] = file size,
  /// [lf] = newline count of the whole file). The newline count must be supplied
  /// by the caller (from the index or a scan); when unknown, pass an estimate
  /// and rebuild later.
  PieceTree.original(int length, int lf) {
    if (length > 0) {
      _root = _Node(0, 0, length, lf);
      _pull(_root!);
    }
  }

  /// Empty document.
  PieceTree.empty();

  int get length => _sb(_root);
  int get lineFeeds => _slf(_root);

  /// Line count (LargeFile convention: newline count + 1; a trailing `\n`
  /// counts one extra empty line at the end).
  int get lineCount => length == 0 ? 0 : _slf(_root) + 1;

  // ── aggregate helpers ───────────────────────────────────────
  static int _h(_Node? n) => n?.height ?? 0;
  static int _sb(_Node? n) => n?.subBytes ?? 0;
  static int _slf(_Node? n) => n?.subLF ?? 0;

  static void _pull(_Node n) {
    n.subBytes = n.length + _sb(n.left) + _sb(n.right);
    n.subLF = n.lf + _slf(n.left) + _slf(n.right);
    final hl = _h(n.left), hr = _h(n.right);
    n.height = 1 + (hl > hr ? hl : hr);
  }

  static int _bf(_Node n) => _h(n.left) - _h(n.right);

  // ── rotations (fix parent links, recompute aggregates, update root when needed) ──
  _Node _rotateLeft(_Node x) {
    final y = x.right!;
    x.right = y.left;
    y.left?.parent = x;
    y.parent = x.parent;
    if (x.parent == null) {
      _root = y;
    } else if (x == x.parent!.left) {
      x.parent!.left = y;
    } else {
      x.parent!.right = y;
    }
    y.left = x;
    x.parent = y;
    _pull(x);
    _pull(y);
    return y;
  }

  _Node _rotateRight(_Node x) {
    final y = x.left!;
    x.left = y.right;
    y.right?.parent = x;
    y.parent = x.parent;
    if (x.parent == null) {
      _root = y;
    } else if (x == x.parent!.left) {
      x.parent!.left = y;
    } else {
      x.parent!.right = y;
    }
    y.right = x;
    x.parent = y;
    _pull(x);
    _pull(y);
    return y;
  }

  // Recompute aggregates and AVL-rebalance all the way up from [from].
  void _rebalanceUp(_Node? from) {
    var n = from;
    while (n != null) {
      _pull(n);
      final bf = _bf(n);
      if (bf > 1) {
        if (_bf(n.left!) < 0) _rotateLeft(n.left!);
        n = _rotateRight(n);
      } else if (bf < -1) {
        if (_bf(n.right!) > 0) _rotateRight(n.right!);
        n = _rotateLeft(n);
      }
      n = n.parent;
    }
  }

  // ── traversal helpers ───────────────────────────────────────
  static _Node _leftmost(_Node n) {
    var c = n;
    while (c.left != null) {
      c = c.left!;
    }
    return c;
  }

  static _Node _rightmost(_Node n) {
    var c = n;
    while (c.right != null) {
      c = c.right!;
    }
    return c;
  }

  static _Node? _successor(_Node n) {
    if (n.right != null) return _leftmost(n.right!);
    var c = n;
    while (c.parent != null && c == c.parent!.right) {
      c = c.parent!;
    }
    return c.parent;
  }

  // Find the node containing [offset] and the displacement inside it;
  // offset == length (or beyond) returns (null, 0).
  (_Node?, int) _descend(int offset) {
    var n = _root;
    var o = offset;
    while (n != null) {
      final lb = _sb(n.left);
      if (o < lb) {
        n = n.left;
      } else {
        final o2 = o - lb;
        if (o2 < n.length) return (n, o2);
        o = o2 - n.length;
        n = n.right;
      }
    }
    return (null, 0);
  }

  // ── public queries ──────────────────────────────────────────

  /// Locate [offset] (with the bytes/newlines accumulated before it);
  /// offset == length returns null.
  PieceLoc? locate(int offset) {
    var n = _root;
    var o = offset;
    var bytesBefore = 0;
    var lfBefore = 0;
    while (n != null) {
      final lb = _sb(n.left);
      final llf = _slf(n.left);
      if (o < lb) {
        n = n.left;
      } else {
        final o2 = o - lb;
        if (o2 < n.length) {
          return PieceLoc(
            buffer: n.buffer,
            bufStart: n.start,
            within: o2,
            pieceLen: n.length,
            pieceLF: n.lf,
            lfBefore: lfBefore + llf,
            pieceStart: bytesBefore + lb,
          );
        }
        bytesBefore += lb + n.length;
        lfBefore += llf + n.lf;
        o -= lb + n.length;
        n = n.right;
      }
    }
    return null;
  }

  /// Visit each piece slice (buffer, bufStart, len) in order starting at
  /// [offset]. Stops when [cb] returns false. Used by the layer above to read
  /// windows.
  void visitFrom(
    int offset,
    bool Function(int buffer, int bufStart, int len) cb,
  ) {
    var (node, within) = _descend(offset);
    while (node != null) {
      if (!cb(node.buffer, node.start + within, node.length - within)) return;
      within = 0;
      node = _successor(node);
    }
  }

  /// Collect all piece slices from [offset] to the end of the document (usually
  /// few: the tail of the original file plus a handful of edits).
  List<PieceRef> piecesFrom(int offset) {
    final out = <PieceRef>[];
    visitFrom(offset, (b, s, l) {
      out.add(PieceRef(b, s, l, 0)); // reading does not need lf; fill 0
      return true;
    });
    return out;
  }

  // ── mutations: split / insert / remove ──────────────────────

  /// Ensure there is a piece boundary at document [offset].
  /// If the offset falls inside a piece, split it in two (newline count of the
  /// left part = [lfLeft], computed by the caller). No-op when already on a
  /// boundary or at EOF.
  void splitAt(int offset, int lfLeft) {
    final (node, within) = _descend(offset);
    if (node == null || within == 0) return; // EOF or already on a boundary
    final rightLen = node.length - within;
    final rightLF = node.lf - lfLeft;
    final right = _Node(node.buffer, node.start + within, rightLen, rightLF);
    node.length = within;
    node.lf = lfLeft;
    _insertAfter(node, right);
  }

  /// Set the newline count of the single original piece to [lf] (used to
  /// correct it before the first edit). Only takes effect while the root is the
  /// only node (i.e. no split/edit has happened yet).
  void setSinglePieceLf(int lf) {
    final r = _root;
    if (r != null && r.left == null && r.right == null) {
      r.lf = lf;
      _pull(r);
    }
  }

  /// Insert a piece at boundary [offset] (call [splitAt] first to ensure the boundary).
  void insertPieceAt(int offset, int buffer, int start, int length, int lf) {
    final fresh = _Node(buffer, start, length, lf);
    if (_root == null) {
      _root = fresh;
      _pull(fresh);
      return;
    }
    final (node, within) = _descend(offset);
    if (node == null) {
      _insertAfter(_rightmost(_root!), fresh); // append at EOF
    } else {
      // within should be 0 (a boundary); insert before that node.
      _insertBefore(node, fresh);
    }
  }

  /// Remove [offset, offset+length) (call [splitAt] at both ends first).
  /// Returns the sequence of removed pieces.
  List<PieceRef> removeRange(int offset, int length) {
    final removed = <PieceRef>[];
    var remaining = length;
    while (remaining > 0) {
      final (node, _) = _descend(offset);
      if (node == null) break;
      removed.add(PieceRef(node.buffer, node.start, node.length, node.lf));
      remaining -= node.length;
      _remove(node);
    }
    return removed;
  }

  void _insertAfter(_Node x, _Node fresh) {
    if (x.right == null) {
      x.right = fresh;
      fresh.parent = x;
    } else {
      final s = _leftmost(x.right!);
      s.left = fresh;
      fresh.parent = s;
    }
    _rebalanceUp(fresh);
  }

  void _insertBefore(_Node x, _Node fresh) {
    if (x.left == null) {
      x.left = fresh;
      fresh.parent = x;
    } else {
      final p = _rightmost(x.left!);
      p.right = fresh;
      fresh.parent = p;
    }
    _rebalanceUp(fresh);
  }

  void _remove(_Node z) {
    // y = the node actually spliced out (has at most one child)
    final _Node y = (z.left == null || z.right == null)
        ? z
        : _leftmost(z.right!);
    final x = y.left ?? y.right; // y's only child (may be null)
    final yp = y.parent;
    if (x != null) x.parent = yp;
    if (yp == null) {
      _root = x;
    } else if (y == yp.left) {
      yp.left = x;
    } else {
      yp.right = x;
    }
    if (!identical(y, z)) {
      // Move y's piece data into z (keeping z's position in the tree)
      z.buffer = y.buffer;
      z.start = y.start;
      z.length = y.length;
      z.lf = y.lf;
    }
    _rebalanceUp(yp);
  }

  // ── test/debug: invariant checks ────────────────────────────

  /// Return all pieces in order (for tests).
  List<PieceRef> debugPieces() {
    final out = <PieceRef>[];
    var n = _root == null ? null : _leftmost(_root!);
    while (n != null) {
      out.add(PieceRef(n.buffer, n.start, n.length, n.lf));
      n = _successor(n);
    }
    return out;
  }

  /// Verify AVL balance and aggregate consistency; returns an error description
  /// on mismatch, null when everything is fine.
  String? validate() {
    String? err;
    int check(_Node? n) {
      if (n == null) return 0;
      if (err != null) return 0;
      // parent links
      if (n.left != null && !identical(n.left!.parent, n)) {
        err = 'left.parent mismatch';
      }
      if (n.right != null && !identical(n.right!.parent, n)) {
        err = 'right.parent mismatch';
      }
      check(n.left);
      check(n.right);
      // aggregates
      final eb = n.length + _sb(n.left) + _sb(n.right);
      final elf = n.lf + _slf(n.left) + _slf(n.right);
      if (n.subBytes != eb) err ??= 'subBytes mismatch (${n.subBytes}≠$eb)';
      if (n.subLF != elf) err ??= 'subLF mismatch (${n.subLF}≠$elf)';
      // AVL balance
      final bf = _h(n.left) - _h(n.right);
      if (bf < -1 || bf > 1) err ??= 'AVL unbalanced (bf=$bf)';
      if (n.length <= 0) err ??= 'non-positive piece length (${n.length})';
      return 0;
    }

    check(_root);
    if (_root != null && _root!.parent != null) err ??= 'root.parent is not null';
    return err;
  }
}
