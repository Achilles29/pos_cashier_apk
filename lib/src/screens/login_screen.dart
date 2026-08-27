import 'package:flutter/material.dart';

import '../models.dart';
import '../services/finance_api_client.dart';
import '../services/settings_store.dart';
import 'setup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.settings,
    required this.settingsStore,
    required this.onLoggedIn,
    required this.onOpenSetup,
  });

  final AppSettings settings;
  final SettingsStore settingsStore;
  final VoidCallback onLoggedIn;
  final VoidCallback onOpenSetup;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _identifier = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _busy = false;
  String _message = '';

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final identifier = _identifier.text.trim();
    final password = _password.text;
    if (identifier.isEmpty || password.isEmpty) {
      setState(() => _message = 'Username/email dan password wajib diisi.');
      return;
    }

    setState(() {
      _busy = true;
      _message = '';
    });

    try {
      final api = FinanceApiClient(settings: widget.settings);
      final response = await api.login(
        identifier: identifier,
        password: password,
      );
      final token = response['token']?.toString() ?? '';
      final user = response['user'];
      if (token.isEmpty) {
        throw const FormatException('Server tidak mengirim token mobile.');
      }
      await widget.settingsStore.save(
        widget.settings.copyWith(
          authToken: token,
          authExpiresAt: response['expires_at']?.toString() ?? '',
          username:
              user is Map
                  ? (user['username']?.toString() ?? identifier)
                  : identifier,
        ),
      );
      widget.onLoggedIn();
    } catch (error) {
      setState(() {
        _busy = false;
        _message = error.toString();
      });
    }
  }

  void _openSetup() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => SetupScreen(
              initialSettings: widget.settings,
              settingsStore: widget.settingsStore,
              onSaved: () {
                Navigator.of(context).pop();
                widget.onOpenSetup();
              },
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Login Kasir',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 6),
                        Text(widget.settings.normalizedBackendUrl),
                        const SizedBox(height: 20),
                        TextField(
                          controller: _identifier,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Username atau email',
                            prefixIcon: Icon(Icons.person),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _password,
                          obscureText: true,
                          onSubmitted: (_) => _busy ? null : _login(),
                          decoration: const InputDecoration(
                            labelText: 'Password',
                            prefixIcon: Icon(Icons.lock),
                          ),
                        ),
                        if (_message.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            _message,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed: _busy ? null : _login,
                              icon:
                                  _busy
                                      ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                      : const Icon(Icons.login),
                              label: const Text('Masuk'),
                            ),
                            const SizedBox(width: 8),
                            TextButton.icon(
                              onPressed: _busy ? null : _openSetup,
                              icon: const Icon(Icons.settings),
                              label: const Text('Pengaturan'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
