// Dispose a dialog's controller only after the dialog is really gone.
//
// `await showDialog(...)` returns when the route pops, but the dialog keeps
// rebuilding through its exit animation — a TextField whose controller was
// disposed right then throws "used after being disposed". Deferring past
// the transition avoids that without owning the controller in a State.

import 'package:flutter/foundation.dart';

void disposeLater(ChangeNotifier c) =>
    Future<void>.delayed(const Duration(milliseconds: 600), c.dispose);
