// Donate dialog: thanks text + external sponsor links (opened in the system
// browser) + an honor-system "I already donated" button that hides the AppBar
// donate button (persisted in settings.json's `donation.hideButton`; the Help
// menu entry stays as a permanent way back in).

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import 'about_page.dart' show projectUrl;
import 'app_settings.dart';

/// Sponsor pages listed in the dialog. Placeholder URLs — replace with the
/// real accounts before release.
const List<(String, String)> donateLinks = [
  ('Buy Me a Bubble Tea', 'https://madedit.bobaboba.me/'),
  ('Ko-fi', 'https://ko-fi.com/madedit'),
  ('PayPal', 'https://paypal.me/madedit'),
];

/// Show the donate page as a modal dialog.
Future<void> showDonateDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const DonateDialog());

class DonateDialog extends StatefulWidget {
  const DonateDialog({super.key});

  @override
  State<DonateDialog> createState() => _DonateDialogState();
}

class _DonateDialogState extends State<DonateDialog> {
  AppLocalizations get _l10n => AppLocalizations.of(context);

  Future<void> _open(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.trf('donate_link_failed', [url]))),
      );
    }
  }

  // Honor system: no server-side verification, just hide the button and thank
  // the user. The Help menu can always reopen this dialog (and un-hide).
  // Not awaited: the field is set and listeners notified synchronously, only
  // the settings.json write is async (same as the shell's keymap handling).
  void _setHidden(bool hidden) {
    AppSettings.instance.setDonateHidden(hidden);
    if (hidden) {
      final messenger = ScaffoldMessenger.of(context);
      final msg = _l10n.tr('donate_hidden_snack');
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final hidden = AppSettings.instance.donateHidden;
    return AlertDialog(
      title: Text(_l10n.tr('donate_title')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _l10n.tr(hidden ? 'donate_thanks' : 'donate_pitch'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              // Open-source note + project link; shown regardless of the
              // hidden state.
              Text(
                _l10n.tr('donate_open_source'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  icon: const Icon(Icons.code, size: 18),
                  label: Text(_l10n.tr('donate_source_link')),
                  onPressed: () => _open(projectUrl),
                ),
              ),
              const SizedBox(height: 8),
              for (final (name, url) in donateLinks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(name),
                    onPressed: () => _open(url),
                  ),
                ),
              const Divider(height: 24),
              if (!hidden)
                TextButton(
                  onPressed: () => _setHidden(true),
                  child: Text(_l10n.tr('donate_hide')),
                )
              else
                TextButton(
                  onPressed: () => _setHidden(false),
                  child: Text(_l10n.tr('donate_show')),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_l10n.tr('common_close')),
        ),
      ],
    );
  }
}
