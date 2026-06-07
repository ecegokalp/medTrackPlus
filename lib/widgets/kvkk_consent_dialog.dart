import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Modal that displays the KVKK + liability disclaimer for video verification
/// recording. Shows a scrollable terms area; the "Kabul Ediyorum" button is
/// disabled until the user scrolls to the bottom.
///
/// Returns `true` if the user accepts, `false` (or `null` on dismiss) otherwise.
class KvkkConsentDialog extends StatefulWidget {
  const KvkkConsentDialog({super.key});

  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const KvkkConsentDialog(),
    );
    return result ?? false;
  }

  @override
  State<KvkkConsentDialog> createState() => _KvkkConsentDialogState();
}

class _KvkkConsentDialogState extends State<KvkkConsentDialog> {
  final ScrollController _scrollController = ScrollController();
  bool _scrolledToBottom = false;
  bool _checkboxAccepted = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrolledToBottom &&
        _scrollController.offset >=
            _scrollController.position.maxScrollExtent - 24) {
      setState(() => _scrolledToBottom = true);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canAccept = _scrolledToBottom && _checkboxAccepted;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Row(
                children: [
                  const Icon(Icons.privacy_tip_rounded,
                      color: Color(0xFF1D8AD6), size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'kvkk_dialog_title'.tr(),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: Color(0xFF0F5191),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Section(
                        title: 'kvkk_section1_title'.tr(),
                        body: 'kvkk_section1_body'.tr(),
                      ),
                      _Section(
                        title: 'kvkk_section2_title'.tr(),
                        body: 'kvkk_section2_body'.tr(),
                      ),
                      _Section(
                        title: 'kvkk_section3_title'.tr(),
                        body: 'kvkk_section3_body'.tr(),
                      ),
                      _Section(
                        title: 'kvkk_section4_title'.tr(),
                        body: 'kvkk_section4_body'.tr(),
                      ),
                      _Section(
                        title: 'kvkk_section5_title'.tr(),
                        body: 'kvkk_section5_body'.tr(),
                      ),
                      _Section(
                        title: 'kvkk_section6_title'.tr(),
                        body: 'kvkk_section6_body'.tr(),
                      ),
                      _Section(
                        title: 'kvkk_section7_title'.tr(),
                        body: 'kvkk_section7_body'.tr(),
                      ),
                      _Section(
                        title: 'kvkk_section8_title'.tr(),
                        body: 'kvkk_section8_body'.tr(),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Checkbox(
                    value: _checkboxAccepted,
                    onChanged: _scrolledToBottom
                        ? (v) => setState(() => _checkboxAccepted = v ?? false)
                        : null,
                  ),
                  Expanded(
                    child: Text(
                      _scrolledToBottom
                          ? 'kvkk_checkbox_accept'.tr()
                          : 'kvkk_scroll_hint'.tr(),
                      style: TextStyle(
                        fontSize: 13,
                        color: _scrolledToBottom
                            ? const Color(0xFF334155)
                            : Colors.grey.shade500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text('kvkk_reject_btn'.tr()),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1D8AD6),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade300,
                    ),
                    onPressed: canAccept
                        ? () => Navigator.of(context).pop(true)
                        : null,
                    child: Text('kvkk_accept_btn'.tr()),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String body;
  const _Section({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: Color(0xFF0F5191),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: Color(0xFF334155),
            ),
          ),
        ],
      ),
    );
  }
}
