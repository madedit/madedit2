// Three-way merge for the menu tree, so a new app version's menu changes reach
// users who already have an external settings/menus/main_menu.json.
//
// The seeded copy is never overwritten (that is what keeps a user's edits), so
// without this the file is frozen at whatever the app shipped when they first
// launched: new items never appear, renamed or removed ones linger. The old
// answer was a hand-written backfill per action inside _loadMenus — ~230 lines
// that only ever handled "add", guessed positions from an anchor that the user
// may have moved, and grew with every menu change.
//
// Instead, keep a snapshot of the defaults the user's file was last reconciled
// against (`main_menu.base.json`) and merge base → user with base → new the way
// a VCS would:
//
//   in new, not in base      a genuinely new item        insert (position from new)
//   in base, not in new      dropped from the defaults   remove
//   in both, user untouched  a default that changed      take the new properties
//   in both, user changed    the user's customisation    keep theirs
//
// Node identity is the action, or `dyn:<id>` for a dynamic placeholder, or
// `label:<labelKey>` for a submenu container. Separators carry no identity and
// are always the user's to arrange, so they are left exactly as they are.
//
// Pure Dart (no Flutter, no IO) — see tool/menu_merge_test.dart.

import 'json_menu_bar.dart';

/// What a merge did, for the log.
class MenuMergeResult {
  const MenuMergeResult(this.menus, {this.added = const [], this.removed = const [], this.updated = const []});

  final List<MenuNode> menus;
  final List<String> added;
  final List<String> removed;
  final List<String> updated;

  bool get changed => added.isNotEmpty || removed.isNotEmpty || updated.isNotEmpty;

  @override
  String toString() =>
      'added ${added.length} $added, removed ${removed.length} $removed, '
      'updated ${updated.length} $updated';
}

/// Stable identity of [n], or null for a separator (nothing to match on).
String? menuNodeId(MenuNode n) {
  if (n.isSeparator) return null;
  if (n.action != null && n.action!.isNotEmpty) return n.action!;
  if (n.dynamicId != null && n.dynamicId!.isNotEmpty) return 'dyn:${n.dynamicId}';
  if (n.labelKey != null && n.labelKey!.isNotEmpty) return 'label:${n.labelKey}';
  return null;
}

/// Every identity in [nodes] (recursive).
Set<String> menuIds(List<MenuNode> nodes) {
  final out = <String>{};
  void walk(List<MenuNode> ns) {
    for (final n in ns) {
      final id = menuNodeId(n);
      if (id != null) out.add(id);
      if (n.children != null) walk(n.children!);
    }
  }

  walk(nodes);
  return out;
}

/// Drop nodes whose identity already appeared earlier (keeping the first).
///
/// A safety net rather than merge logic: a bad edit once shipped a default menu
/// with an entire duplicated `menu_run` and two copies of a couple of items, and
/// every user seeded from it carries them.
List<MenuNode> dedupeMenus(List<MenuNode> nodes, [Set<String>? seen]) {
  final s = seen ?? <String>{};
  final out = <MenuNode>[];
  for (final n in nodes) {
    final id = menuNodeId(n);
    if (id != null && !s.add(id)) continue; // already had this one
    out.add(
      n.children == null ? n : _withChildren(n, dedupeMenus(n.children!, s)),
    );
  }
  return out;
}

/// Merge the packaged defaults [def] into the user's tree [user], using [base]
/// — the defaults the user's tree was last reconciled with — to tell "the user
/// changed this" apart from "the defaults changed this".
///
/// [deleted] are the nodes the user explicitly removed in the menu editor; those
/// identities are never re-added. Pass [base] as null on the first run (no
/// snapshot yet): the merge is then additive only — new defaults are inserted,
/// nothing is removed and no properties are overwritten — so a user who edited
/// their menu long before this mechanism existed cannot lose anything.
MenuMergeResult mergeMenus({
  required List<MenuNode> user,
  required List<MenuNode> def,
  List<MenuNode>? base,
  List<MenuNode> deleted = const [],
}) {
  final additive = base == null;
  final baseIds = additive ? <String>{} : menuIds(base);
  final defIds = menuIds(def);
  final deletedIds = menuIds(deleted);

  final added = <String>[];
  final removed = <String>[];
  final updated = <String>[];

  final baseById = additive ? <String, MenuNode>{} : _byId(base);
  final defById = _byId(def);

  // 1. Remove what the defaults dropped (never in additive mode: with no
  //    snapshot, "missing from the defaults" cannot be told from "the user's
  //    own addition", and this project's menu editor cannot add items anyway).
  List<MenuNode> prune(List<MenuNode> ns) {
    final out = <MenuNode>[];
    for (final n in ns) {
      final id = menuNodeId(n);
      if (!additive && id != null && baseIds.contains(id) && !defIds.contains(id)) {
        removed.add(id);
        continue;
      }
      out.add(n.children == null ? n : _withChildren(n, prune(n.children!)));
    }
    return out;
  }

  // 2. Adopt property changes the user never touched (label/shortcut/icon).
  List<MenuNode> refresh(List<MenuNode> ns) {
    if (additive) return ns;
    return [
      for (final n in ns)
        () {
          var m = n;
          final id = menuNodeId(n);
          final b = id == null ? null : baseById[id];
          final d = id == null ? null : defById[id];
          if (b != null && d != null && _sameProps(n, b) && !_sameProps(n, d)) {
            updated.add(id!);
            m = _withProps(n, d);
          }
          return m.children == null ? m : _withChildren(m, refresh(m.children!));
        }(),
    ];
  }

  var out = refresh(prune(user));

  // 3. Insert what the defaults gained, at the place the defaults put it.
  final present = menuIds(out);
  void insertNew(List<MenuNode> defNodes, List<MenuNode>? Function() target) {
    for (var i = 0; i < defNodes.length; i++) {
      final d = defNodes[i];
      final id = menuNodeId(d);
      if (id == null) continue; // separators belong to the user's arrangement
      final isNew = !present.contains(id) &&
          (additive || !baseIds.contains(id)) &&
          !deletedIds.contains(id);
      if (isNew) {
        final list = target();
        if (list != null) {
          // Put it after the nearest preceding sibling that the user still has,
          // so an item keeps its neighbourhood even in a rearranged menu.
          var at = list.length;
          for (var j = i - 1; j >= 0; j--) {
            final anchor = menuNodeId(defNodes[j]);
            if (anchor == null) continue;
            final k = list.indexWhere((n) => menuNodeId(n) == anchor);
            if (k >= 0) {
              at = k + 1;
              break;
            }
          }
          list.insert(at, d);
          present.addAll(menuIds([d]));
          added.add(id);
          continue; // its children came with it
        }
      }
      if (d.children != null) {
        // Recurse into the user's copy of this submenu (null when they turned
        // it into a leaf or it is missing — then there is nowhere to insert).
        insertNew(d.children!, () => _childrenOf(out, id));
      }
    }
  }

  // The root list is mutable so inserts can happen in place.
  final root = List<MenuNode>.from(out);
  out = root;
  insertNew(def, () => root);

  return MenuMergeResult(out, added: added, removed: removed, updated: updated);
}

Map<String, MenuNode> _byId(List<MenuNode> nodes) {
  final out = <String, MenuNode>{};
  void walk(List<MenuNode> ns) {
    for (final n in ns) {
      final id = menuNodeId(n);
      if (id != null) out.putIfAbsent(id, () => n);
      if (n.children != null) walk(n.children!);
    }
  }

  walk(nodes);
  return out;
}

/// The children list of the node with [id], or null when absent / a leaf.
List<MenuNode>? _childrenOf(List<MenuNode> nodes, String id) {
  for (final n in nodes) {
    if (menuNodeId(n) == id) return n.children;
    if (n.children != null) {
      final r = _childrenOf(n.children!, id);
      if (r != null) return r;
    }
  }
  return null;
}

bool _sameProps(MenuNode a, MenuNode b) =>
    a.labelKey == b.labelKey &&
    a.shortcut == b.shortcut &&
    a.icon == b.icon &&
    a.enabled == b.enabled;

MenuNode _withProps(MenuNode n, MenuNode from) => MenuNode(
  labelKey: from.labelKey,
  action: n.action,
  shortcut: from.shortcut,
  icon: from.icon,
  dynamicId: n.dynamicId,
  enabled: from.enabled,
  isSeparator: n.isSeparator,
  children: n.children,
);

MenuNode _withChildren(MenuNode n, List<MenuNode> children) => MenuNode(
  labelKey: n.labelKey,
  action: n.action,
  shortcut: n.shortcut,
  icon: n.icon,
  dynamicId: n.dynamicId,
  enabled: n.enabled,
  isSeparator: n.isSeparator,
  children: children,
);
