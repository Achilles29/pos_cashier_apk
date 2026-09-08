import 'package:flutter/material.dart';

import '../services/finance_api_client.dart';

/// Requests the user's password only at the moment a high-impact action is
/// submitted. Finance receives the password at its verification endpoint and
/// returns a short-lived, one-use proof; the password is never put in the
/// actual void/refund/close request or local database.
Future<String?> requestSensitiveActionProof(
  BuildContext context, {
  required String title,
  required String description,
  required String confirmLabel,
  required Future<Map<String, Object?>> Function(String password) verify,
}) async {
  final password = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        var obscured = true;
        var submitting = false;
        String? errorMessage;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            Future<void> submit() async {
              final value = password.text;
              if (value.isEmpty) {
                setDialogState(() {
                  errorMessage = 'Password wajib diisi untuk melanjutkan.';
                });
                return;
              }
              setDialogState(() {
                submitting = true;
                errorMessage = null;
              });
              try {
                final response = await verify(value);
                final proof = response['step_up_proof']?.toString().trim() ?? '';
                if (proof.isEmpty) {
                  throw StateError('Server tidak mengirim bukti verifikasi.');
                }
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext, proof);
                }
              } catch (error) {
                if (!dialogContext.mounted) return;
                setDialogState(() {
                  submitting = false;
                  errorMessage = error is FinanceApiException
                      ? error.userMessage
                      : 'Verifikasi tidak berhasil. Coba lagi.';
                });
              }
            }

            return AlertDialog(
              icon: Icon(
                Icons.verified_user_outlined,
                color: Theme.of(dialogContext).colorScheme.primary,
              ),
              title: Text(title),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(description),
                    const SizedBox(height: 10),
                    Text(
                      'Password hanya dipakai untuk verifikasi ini dan tidak disimpan di perangkat.',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: password,
                      autofocus: true,
                      enabled: !submitting,
                      obscureText: obscured,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => submit(),
                      decoration: InputDecoration(
                        labelText: 'Password akun Finance',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: obscured ? 'Tampilkan password' : 'Sembunyikan password',
                          onPressed: submitting
                              ? null
                              : () => setDialogState(() => obscured = !obscured),
                          icon: Icon(
                            obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                    ),
                    if (errorMessage != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        errorMessage!,
                        style: TextStyle(
                          color: Theme.of(dialogContext).colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: submitting
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: const Text('Batal'),
                ),
                FilledButton.icon(
                  onPressed: submitting ? null : submit,
                  icon: submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.verified_user_outlined),
                  label: Text(confirmLabel),
                ),
              ],
            );
          },
        );
      },
    );
  } finally {
    password.dispose();
  }
}
