// A VS Code-style quick pick: a text field on top, a fuzzy-filtered list
// below, arrows + Enter to choose. Shared by quick open (ctrl+p), the
// recent-files picker (ctrl+r) and the syntax picker (ctrl+k m). Items can
// keep arriving through [more] (a folder scan) while the user is typing.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor/quick_open.dart';
import '../settings/resizable_dialog.dart';
import '../util/dispose_later.dart';

export '../editor/quick_open.dart' show QuickItem;

/// Returns the chosen item's value, or null when dismissed.
Future<String?> showQuickPick(
  BuildContext context, {
  required String hint,
  required List<QuickItem> items,
  Stream<List<QuickItem>>? more,
  String initialQuery = '',
  String? emptyText,
}) {
  final scrollCtl = ScrollController();
  const rowH = 36.0, listH = 400.0;
  final all = List.of(items);
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      var query = initialQuery;
      var selected = 0;
      StreamSubscription<List<QuickItem>>? sub;
      var subscribed = false;
      return StatefulBuilder(
        builder: (ctx, setSt) {
          if (!subscribed && more != null) {
            subscribed = true;
            sub = more.listen((batch) {
              all.addAll(batch);
              setSt(() {});
            });
          }
          final filtered = rankQuickItems(query, all);
          if (selected >= filtered.length) {
            selected = filtered.isEmpty ? 0 : filtered.length - 1;
          }
          void reveal() {
            if (!scrollCtl.hasClients) return;
            final top = selected * rowH;
            final off = scrollCtl.offset;
            if (top < off) {
              scrollCtl.jumpTo(top);
            } else if (top + rowH > off + listH) {
              scrollCtl.jumpTo(top + rowH - listH);
            }
          }

          void choose() {
            if (selected < filtered.length) {
              sub?.cancel();
              Navigator.pop(ctx, filtered[selected].value);
            }
          }

          final cs = Theme.of(ctx).colorScheme;
          return PopScope(
            onPopInvokedWithResult: (_, _) => sub?.cancel(),
            child: Dialog(
              alignment: Alignment.topCenter,
              insetPadding: const EdgeInsets.only(top: 80),
              child: ResizableDialogBox(
                id: 'quickPick',
                initialWidth: 600,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Focus(
                        onKeyEvent: (node, e) {
                          if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
                            return KeyEventResult.ignored;
                          }
                          final k = e.logicalKey;
                          int d;
                          if (k == LogicalKeyboardKey.arrowDown) {
                            d = 1;
                          } else if (k == LogicalKeyboardKey.arrowUp) {
                            d = -1;
                          } else if (k == LogicalKeyboardKey.pageDown) {
                            d = 10;
                          } else if (k == LogicalKeyboardKey.pageUp) {
                            d = -10;
                          } else {
                            return KeyEventResult.ignored;
                          }
                          setSt(() {
                            if (filtered.isEmpty) return;
                            selected = (selected + d).clamp(
                              0,
                              filtered.length - 1,
                            );
                          });
                          WidgetsBinding.instance.addPostFrameCallback(
                            (_) => reveal(),
                          );
                          return KeyEventResult.handled;
                        },
                        child: TextField(
                          autofocus: true,
                          controller: TextEditingController(text: query)
                            ..selection = TextSelection.collapsed(
                              offset: query.length,
                            ),
                          decoration: InputDecoration(
                            isDense: true,
                            prefixIcon: const Icon(Icons.search, size: 18),
                            hintText: hint,
                          ),
                          onChanged: (v) => setSt(() {
                            query = v;
                            selected = 0;
                          }),
                          onSubmitted: (_) => choose(),
                        ),
                      ),
                    ),
                    if (filtered.isEmpty && emptyText != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          emptyText,
                          style: TextStyle(color: cs.outline),
                        ),
                      ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: listH),
                      child: ListView.builder(
                        controller: scrollCtl,
                        shrinkWrap: true,
                        itemExtent: rowH,
                        itemCount: filtered.length,
                        itemBuilder: (ctx, i) {
                          final e = filtered[i];
                          return InkWell(
                            onTap: () {
                              selected = i;
                              choose();
                            },
                            child: Container(
                              color: i == selected
                                  ? cs.primary.withValues(alpha: 0.15)
                                  : null,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              alignment: Alignment.centerLeft,
                              child: Row(
                                children: [
                                  Text(e.label, overflow: TextOverflow.ellipsis),
                                  if (e.detail.isNotEmpty) ...[
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        e.detail,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: cs.outline,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  ).whenComplete(() => disposeLater(scrollCtl));
}
