import 'dart:io';

/// Minimal EditorConfig support (https://editorconfig.org).
///
/// The parser is deliberately small: it covers the properties this editor can
/// actually use (indent style / indent size / tab width) plus a few common
/// ones kept for callers that want them. No third-party path or glob package
/// is needed, and the pure functions can be tested headlessly.
class EditorConfig {
  final int? tabWidth;
  final bool? insertSpaces;
  final bool? trimTrailingWhitespace;
  final bool? insertFinalNewline;
  final String? endOfLine;
  final int? maxLineLength;

  const EditorConfig({
    this.tabWidth,
    this.insertSpaces,
    this.trimTrailingWhitespace,
    this.insertFinalNewline,
    this.endOfLine,
    this.maxLineLength,
  });

  EditorConfig merge(EditorConfig other) => EditorConfig(
    tabWidth: other.tabWidth ?? tabWidth,
    insertSpaces: other.insertSpaces ?? insertSpaces,
    trimTrailingWhitespace:
        other.trimTrailingWhitespace ?? trimTrailingWhitespace,
    insertFinalNewline: other.insertFinalNewline ?? insertFinalNewline,
    endOfLine: other.endOfLine ?? endOfLine,
    maxLineLength: other.maxLineLength ?? maxLineLength,
  );
}

class EditorConfigSection {
  final String pattern;
  final Map<String, String> props;

  const EditorConfigSection(this.pattern, this.props);
}

class EditorConfigFile {
  final bool root;
  final List<EditorConfigSection> sections;

  const EditorConfigFile({required this.root, required this.sections});
}

EditorConfigFile parseEditorConfig(String content) {
  if (content.startsWith('\uFEFF')) content = content.substring(1);
  var root = false;
  final sections = <EditorConfigSection>[];
  String? pattern;
  Map<String, String>? props;

  void flush() {
    if (pattern != null && props != null) {
      sections.add(EditorConfigSection(pattern!, Map.of(props!)));
    }
    pattern = null;
    props = null;
  }

  for (final raw in content.split(RegExp(r'\r\n|\r|\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
      continue;
    }
    if (line.startsWith('[') && line.endsWith(']')) {
      flush();
      pattern = line.substring(1, line.length - 1).trim();
      props = <String, String>{};
      continue;
    }
    final eq = line.indexOf('=');
    if (eq < 0) continue;
    final key = line.substring(0, eq).trim().toLowerCase();
    final value = line.substring(eq + 1).trim();
    if (pattern == null) {
      if (key == 'root') root = value.toLowerCase() == 'true';
    } else {
      props![key] = value;
    }
  }
  flush();
  return EditorConfigFile(root: root, sections: sections);
}

EditorConfig editorConfigFromProps(Map<String, String> props) {
  final style = props['indent_style']?.trim().toLowerCase();
  final bool? insertSpaces = switch (style) {
    'tab' => false,
    'space' => true,
    _ => null,
  };

  final indentSize = props['indent_size']?.trim().toLowerCase();
  final tabWidth =
      _parseInt(props['tab_width']) ??
      (indentSize == 'tab' ? null : _parseInt(indentSize));

  final trim = _parseBool(props['trim_trailing_whitespace']);
  final finalNewline = _parseBool(props['insert_final_newline']);
  final eol = props['end_of_line']?.trim().toLowerCase();
  final maxLine = _parseInt(props['max_line_length']);

  return EditorConfig(
    tabWidth: tabWidth,
    insertSpaces: insertSpaces,
    trimTrailingWhitespace: trim,
    insertFinalNewline: finalNewline,
    endOfLine: eol,
    maxLineLength: maxLine,
  );
}

Future<EditorConfig> loadEditorConfig(
  String filePath, {
  Future<String?> Function(String path)? readFile,
}) async {
  final reader = readFile ?? _readIfExists;
  final found = <_ConfigWithDir>[];

  var dir = File(filePath).parent.path;
  while (true) {
    final content = await reader(_join(dir, '.editorconfig'));
    if (content != null) {
      final parsed = parseEditorConfig(content);
      found.add(_ConfigWithDir(dir, parsed));
      if (parsed.root) break;
    }
    final parent = Directory(dir).parent.path;
    if (_samePath(parent, dir)) break;
    dir = parent;
  }

  var out = const EditorConfig();
  // Farther files first, so the nearest .editorconfig wins. Within one file,
  // later sections override earlier ones.
  for (final cfg in found.reversed) {
    final rel = _relativePath(cfg.dir, filePath);
    for (final sec in cfg.file.sections) {
      if (editorConfigGlobMatches(sec.pattern, rel)) {
        out = out.merge(editorConfigFromProps(sec.props));
      }
    }
  }
  return out;
}

bool editorConfigGlobMatches(String pattern, String path) {
  final p = pattern.replaceAll(r'\', '/');
  final f = path.replaceAll(r'\', '/');
  final subject = p.contains('/') ? f : f.split('/').last;
  var glob = p;
  if (glob.startsWith('/')) glob = glob.substring(1);
  final re = RegExp('^${_globToRegex(glob)}\$');
  return re.hasMatch(subject);
}

int? _parseInt(String? s) => s == null ? null : int.tryParse(s.trim());

bool? _parseBool(String? s) {
  if (s == null) return null;
  final v = s.trim().toLowerCase();
  if (v == 'true' || v == '1') return true;
  if (v == 'false' || v == '0') return false;
  return null;
}

Future<String?> _readIfExists(String path) async {
  final f = File(path);
  if (!await f.exists()) return null;
  return f.readAsString();
}

String _join(String dir, String name) =>
    dir.endsWith(Platform.pathSeparator)
    ? '$dir$name'
    : '$dir${Platform.pathSeparator}$name';

bool _samePath(String a, String b) =>
    a.replaceAll(r'\', '/').toLowerCase() == b.replaceAll(r'\', '/').toLowerCase();

String _relativePath(String dir, String file) {
  var d = dir.replaceAll(r'\', '/');
  final f = file.replaceAll(r'\', '/');
  if (!d.endsWith('/')) d += '/';
  if (f.toLowerCase().startsWith(d.toLowerCase())) {
    return f.substring(d.length);
  }
  return f.split('/').last;
}

String _globToRegex(String glob) {
  final out = StringBuffer();
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == r'\' && i + 1 < glob.length) {
      out.write(RegExp.escape(glob[++i]));
      continue;
    }
    if (c == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        i++;
        if (i + 1 < glob.length && glob[i + 1] == '/') {
          i++;
          out.write(r'(?:[^/]+/)*');
        } else {
          out.write(r'.*');
        }
      } else {
        out.write(r'[^/]*');
      }
      continue;
    }
    if (c == '?') {
      out.write(r'[^/]');
      continue;
    }
    if (c == '{') {
      final end = _findBraceEnd(glob, i);
      if (end < 0) {
        out.write(RegExp.escape(c));
        continue;
      }
      final alts = _splitTopLevel(glob.substring(i + 1, end));
      out.write('(?:${alts.map(_globToRegex).join('|')})');
      i = end;
      continue;
    }
    if (c == '[') {
      var end = i + 1;
      if (end < glob.length && glob[end] == '!') end++;
      while (end < glob.length && glob[end] != ']') {
        end++;
      }
      if (end >= glob.length) {
        out.write(RegExp.escape(c));
        continue;
      }
      var cls = glob.substring(i + 1, end);
      if (cls.startsWith('!')) cls = '^${cls.substring(1)}';
      out.write('[$cls]');
      i = end;
      continue;
    }
    out.write(RegExp.escape(c));
  }
  return out.toString();
}

int _findBraceEnd(String s, int start) {
  var depth = 0;
  for (var i = start; i < s.length; i++) {
    if (s[i] == r'\') {
      i++;
      continue;
    }
    if (s[i] == '{') {
      depth++;
    } else if (s[i] == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

List<String> _splitTopLevel(String s) {
  final out = <String>[];
  final sb = StringBuffer();
  var depth = 0;
  var inClass = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\') {
      if (i + 1 < s.length) {
        sb.write(c);
        sb.write(s[++i]);
      }
      continue;
    }
    if (!inClass && c == '[') {
      inClass = true;
    } else if (inClass && c == ']') {
      inClass = false;
    }
    if (!inClass) {
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
      } else if (c == ',' && depth == 0) {
        out.add(sb.toString());
        sb.clear();
        continue;
      }
    }
    sb.write(c);
  }
  out.add(sb.toString());
  return out;
}

class _ConfigWithDir {
  final String dir;
  final EditorConfigFile file;

  const _ConfigWithDir(this.dir, this.file);
}
