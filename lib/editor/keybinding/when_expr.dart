/// Minimal evaluator for `when` condition expressions (modelled on VS Code).
///
/// Grammar (precedence from lowest to highest):
///   or        a || b
///   and       a && b
///   not       !a
///   compare   a == 'x'   a != 'x'
///   atom      identifier | 'string' | true | false | ( expr )
///
/// An identifier is looked up in the context map; on its own it is tested
/// for truthiness.
class WhenExpr {
  WhenExpr._(this._root);

  final _Node _root;

  static WhenExpr parse(String src) => WhenExpr._(_Parser(src).parseExpr());

  bool eval(Map<String, Object?> ctx) => _truthy(_root.eval(ctx));
}

bool _truthy(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty && v != 'false';
  return true;
}

abstract class _Node {
  Object? eval(Map<String, Object?> ctx);
}

class _Or extends _Node {
  _Or(this.l, this.r);
  final _Node l, r;
  @override
  Object? eval(ctx) => _truthy(l.eval(ctx)) || _truthy(r.eval(ctx));
}

class _And extends _Node {
  _And(this.l, this.r);
  final _Node l, r;
  @override
  Object? eval(ctx) => _truthy(l.eval(ctx)) && _truthy(r.eval(ctx));
}

class _Not extends _Node {
  _Not(this.e);
  final _Node e;
  @override
  Object? eval(ctx) => !_truthy(e.eval(ctx));
}

class _Cmp extends _Node {
  _Cmp(this.l, this.op, this.r);
  final _Node l, r;
  final String op; // '==' | '!='
  @override
  Object? eval(ctx) {
    final a = l.eval(ctx);
    final b = r.eval(ctx);
    return op == '==' ? a == b : a != b;
  }
}

class _Ident extends _Node {
  _Ident(this.name);
  final String name;
  @override
  Object? eval(ctx) => ctx[name];
}

class _Lit extends _Node {
  _Lit(this.value);
  final Object? value;
  @override
  Object? eval(ctx) => value;
}

class _Parser {
  _Parser(this._s);
  final String _s;
  int _i = 0;

  _Node parseExpr() {
    final n = _parseOr();
    _ws();
    return n;
  }

  _Node _parseOr() {
    var n = _parseAnd();
    while (_match('||')) {
      n = _Or(n, _parseAnd());
    }
    return n;
  }

  _Node _parseAnd() {
    var n = _parseCmp();
    while (_match('&&')) {
      n = _And(n, _parseCmp());
    }
    return n;
  }

  _Node _parseCmp() {
    final n = _parseUnary();
    _ws();
    if (_match('==')) return _Cmp(n, '==', _parseUnary());
    if (_match('!=')) return _Cmp(n, '!=', _parseUnary());
    return n;
  }

  _Node _parseUnary() {
    _ws();
    if (_match('!')) return _Not(_parseUnary());
    return _parsePrimary();
  }

  _Node _parsePrimary() {
    _ws();
    if (_match('(')) {
      final n = _parseOr();
      _ws();
      _match(')');
      return n;
    }
    final c = _peek();
    if (c == '\'' || c == '"') return _parseString(c);
    final id = _parseIdent();
    if (id == 'true') return _Lit(true);
    if (id == 'false') return _Lit(false);
    return _Ident(id);
  }

  _Node _parseString(String quote) {
    _i++; // skip opening quote
    final sb = StringBuffer();
    while (_i < _s.length && _s[_i] != quote) {
      sb.write(_s[_i++]);
    }
    if (_i < _s.length) _i++; // closing quote
    return _Lit(sb.toString());
  }

  String _parseIdent() {
    _ws();
    final start = _i;
    while (_i < _s.length && RegExp(r'[A-Za-z0-9_.]').hasMatch(_s[_i])) {
      _i++;
    }
    return _s.substring(start, _i);
  }

  void _ws() {
    while (_i < _s.length && _s[_i] == ' ') {
      _i++;
    }
  }

  String _peek() {
    _ws();
    return _i < _s.length ? _s[_i] : '';
  }

  bool _match(String tok) {
    _ws();
    if (_s.startsWith(tok, _i)) {
      _i += tok.length;
      return true;
    }
    return false;
  }
}
