import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const int pinLength = 6;
const int maxPinAttempts = 5;

/// A salted PIN hash (the PIN itself is never stored).
class PinRecord {
  const PinRecord({required this.salt, required this.hash});
  final String salt;
  final String hash;
}

/// Stores each account's salted PIN hash in the Realtime Database at
/// `users/<uid>/pin`, so the PIN follows the account across devices. A copy is
/// cached in the platform secure storage so unlocking still works offline.
class PinService {
  PinService._();

  static const _storage = FlutterSecureStorage();
  static const _timeout = Duration(seconds: 10);

  static String _key(String uid, String field) => 'pin_${field}_$uid';

  static DatabaseReference _ref(String uid) =>
      FirebaseDatabase.instance.ref('users/$uid/pin');

  static String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  /// Returns the account's PIN record, or null when no PIN has been set.
  /// Throws if the database is unreachable and nothing is cached.
  static Future<PinRecord?> load(String uid) async {
    try {
      final snapshot = await _ref(uid).get().timeout(_timeout);
      final value = snapshot.value;
      if (value is Map && value['salt'] is String && value['hash'] is String) {
        final record = PinRecord(
          salt: value['salt'] as String,
          hash: value['hash'] as String,
        );
        await _cache(uid, record);
        return record;
      }
      await _clearCache(uid);
      return null;
    } catch (_) {
      final cached = await _cached(uid);
      if (cached != null) return cached;
      rethrow;
    }
  }

  /// Saves a new PIN for the account (used for first-time setup, change and
  /// forgot-PIN reset).
  static Future<PinRecord> save(String uid, String pin) async {
    final random = Random.secure();
    final salt = base64UrlEncode(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    final record = PinRecord(salt: salt, hash: _hash(pin, salt));
    await _ref(uid)
        .set({'salt': record.salt, 'hash': record.hash})
        .timeout(_timeout);
    await _cache(uid, record);
    await _storage.write(key: _key(uid, 'fails'), value: '0');
    return record;
  }

  /// Returns the number of consecutive failed attempts (0 when [pin] is correct).
  static Future<int> verify(String uid, PinRecord record, String pin) async {
    if (_hash(pin, record.salt) == record.hash) {
      await _storage.write(key: _key(uid, 'fails'), value: '0');
      return 0;
    }
    final fails =
        (int.tryParse(await _storage.read(key: _key(uid, 'fails')) ?? '') ??
            0) +
        1;
    await _storage.write(key: _key(uid, 'fails'), value: '$fails');
    return fails;
  }

  /// Removes only the local cache; the PIN stays on the account.
  static Future<void> clearLocal(String uid) async {
    await _clearCache(uid);
    await _storage.delete(key: _key(uid, 'fails'));
  }

  static Future<void> _cache(String uid, PinRecord record) async {
    await _storage.write(key: _key(uid, 'salt'), value: record.salt);
    await _storage.write(key: _key(uid, 'hash'), value: record.hash);
  }

  static Future<PinRecord?> _cached(String uid) async {
    final salt = await _storage.read(key: _key(uid, 'salt'));
    final hash = await _storage.read(key: _key(uid, 'hash'));
    return salt == null || hash == null
        ? null
        : PinRecord(salt: salt, hash: hash);
  }

  static Future<void> _clearCache(String uid) async {
    await _storage.delete(key: _key(uid, 'salt'));
    await _storage.delete(key: _key(uid, 'hash'));
  }
}

/// Tracks whether the app is currently locked behind the PIN screen.
class AppLock extends ChangeNotifier {
  AppLock._();
  static final AppLock instance = AppLock._();

  bool _locked = true; // Locked on every cold start.
  bool get locked => _locked;

  void lock() {
    if (_locked) return;
    _locked = true;
    notifyListeners();
  }

  void unlock() {
    if (!_locked) return;
    _locked = false;
    notifyListeners();
  }
}

/// Signs the user out. The PIN stays on the account; only the local cache is
/// removed. Logging in again will ask for the existing PIN.
Future<void> signOutUser() async {
  final user = FirebaseAuth.instance.currentUser;
  AppLock.instance.lock();
  await FirebaseAuth.instance.signOut();
  if (user != null) await PinService.clearLocal(user.uid);
}

String _wrongPinMessage(int fails) {
  final left = maxPinAttempts - fails;
  return 'Incorrect PIN. $left attempt${left == 1 ? '' : 's'} left.';
}

/// Obscured numeric field that reports the PIN once [pinLength] digits are typed.
class PinField extends StatefulWidget {
  const PinField({
    super.key,
    required this.onCompleted,
    this.enabled = true,
    this.errorText,
  });

  final ValueChanged<String> onCompleted;
  final bool enabled;
  final String? errorText;

  @override
  State<PinField> createState() => _PinFieldState();
}

class _PinFieldState extends State<PinField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void didUpdateWidget(PinField old) {
    super.didUpdateWidget(old);
    // Regain keyboard focus after being disabled during verification.
    if (widget.enabled && !old.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    if (value.length == pinLength) {
      widget.onCompleted(value);
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      autofocus: true,
      enabled: widget.enabled,
      obscureText: true,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      maxLength: pinLength,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: const TextStyle(fontSize: 28, letterSpacing: 12),
      onChanged: _onChanged,
      decoration: InputDecoration(
        counterText: '',
        border: const OutlineInputBorder(),
        errorText: widget.errorText,
      ),
    );
  }
}

class _PinScaffold extends StatelessWidget {
  const _PinScaffold({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(
                        Icons.lock_outline,
                        size: 48,
                        color: Color(0xFF205D36),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF205D36),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.black54),
                      ),
                      const SizedBox(height: 20),
                      child,
                    ],
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

/// Shown when the account has no PIN yet, or after a verified forgot-PIN reset.
class SetPinPage extends StatefulWidget {
  const SetPinPage({
    super.key,
    required this.uid,
    required this.onDone,
    this.onCancel,
  });

  final String uid;
  final VoidCallback onDone;

  /// When set, shows "Cancel" instead of "Sign out".
  final VoidCallback? onCancel;

  @override
  State<SetPinPage> createState() => _SetPinPageState();
}

class _SetPinPageState extends State<SetPinPage> {
  String? _firstPin;
  String? _error;
  bool _saving = false;

  Future<void> _onPin(String pin) async {
    if (_firstPin == null) {
      setState(() {
        _firstPin = pin;
        _error = null;
      });
      return;
    }
    if (pin != _firstPin) {
      setState(() {
        _firstPin = null;
        _error = 'PINs did not match. Try again.';
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await PinService.save(widget.uid, pin);
      widget.onDone();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _firstPin = null;
        _error = 'Could not save the PIN. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final confirming = _firstPin != null;
    return _PinScaffold(
      title: confirming ? 'Confirm PIN' : 'Create a PIN',
      subtitle: confirming
          ? 'Enter the same $pinLength-digit PIN again.'
          : 'Choose a $pinLength-digit PIN to unlock the app next time.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PinField(
            key: ValueKey(confirming),
            enabled: !_saving,
            errorText: _error,
            onCompleted: _onPin,
          ),
          TextButton(
            onPressed: _saving ? null : (widget.onCancel ?? signOutUser),
            child: Text(widget.onCancel != null ? 'Cancel' : 'Sign out'),
          ),
        ],
      ),
    );
  }
}

/// Shown whenever the app is opened and the account has a PIN.
class UnlockPage extends StatefulWidget {
  const UnlockPage({
    super.key,
    required this.user,
    required this.record,
    required this.onUnlocked,
    required this.onForgot,
  });

  final User user;
  final PinRecord record;
  final VoidCallback onUnlocked;

  /// Called after the account password has been re-verified.
  final VoidCallback onForgot;

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  String? _error;
  bool _busy = false;

  Future<void> _onPin(String pin) async {
    setState(() => _busy = true);
    final fails = await PinService.verify(widget.user.uid, widget.record, pin);
    if (!mounted) return;
    if (fails == 0) {
      widget.onUnlocked();
      return;
    }
    if (fails >= maxPinAttempts) {
      await signOutUser();
      return;
    }
    setState(() {
      _busy = false;
      _error = _wrongPinMessage(fails);
    });
  }

  Future<void> _forgotPin() async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _PasswordDialog(),
    );
    if (password == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.user.reauthenticateWithCredential(
        EmailAuthProvider.credential(
          email: widget.user.email ?? '',
          password: password,
        ),
      );
      if (!mounted) return;
      widget.onForgot();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.code == 'network-request-failed'
            ? 'Network error. Check your connection.'
            : e.code == 'too-many-requests'
            ? 'Too many attempts. Try again later.'
            : 'Incorrect password.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _PinScaffold(
      title: 'Enter PIN',
      subtitle: widget.user.email ?? 'Unlock ECOCYCLE',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PinField(enabled: !_busy, errorText: _error, onCompleted: _onPin),
          TextButton(
            onPressed: _busy ? null : _forgotPin,
            child: const Text('Forgot PIN?'),
          ),
          TextButton(
            onPressed: _busy ? null : signOutUser,
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text.isNotEmpty)
      Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reset PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Enter your account password to set a new PIN.'),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: _obscure,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Continue')),
      ],
    );
  }
}

/// Change the PIN: verify the current one, then enter and confirm a new one.
class ChangePinPage extends StatefulWidget {
  const ChangePinPage({super.key, required this.uid});

  final String uid;

  @override
  State<ChangePinPage> createState() => _ChangePinPageState();
}

class _ChangePinPageState extends State<ChangePinPage> {
  int _stage = 0; // 0 = current PIN, 1 = new PIN, 2 = confirm new PIN
  String? _newPin;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    AppLock.instance.addListener(_onLockChanged);
  }

  @override
  void dispose() {
    AppLock.instance.removeListener(_onLockChanged);
    super.dispose();
  }

  // Never leave this page visible over a locked app.
  void _onLockChanged() {
    if (AppLock.instance.locked && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  Future<void> _onPin(String pin) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      switch (_stage) {
        case 0:
          final record = await PinService.load(widget.uid);
          if (record == null) throw StateError('No PIN set');
          final fails = await PinService.verify(widget.uid, record, pin);
          if (!mounted) return;
          if (fails == 0) {
            setState(() {
              _stage = 1;
              _busy = false;
            });
          } else if (fails >= maxPinAttempts) {
            final navigator = Navigator.of(context);
            await signOutUser();
            navigator.popUntil((r) => r.isFirst);
          } else {
            setState(() {
              _busy = false;
              _error = _wrongPinMessage(fails);
            });
          }
        case 1:
          setState(() {
            _newPin = pin;
            _stage = 2;
            _busy = false;
          });
        case 2:
          if (pin != _newPin) {
            setState(() {
              _newPin = null;
              _stage = 1;
              _busy = false;
              _error = 'PINs did not match. Try again.';
            });
            return;
          }
          await PinService.save(widget.uid, pin);
          if (!mounted) return;
          final messenger = ScaffoldMessenger.of(context);
          Navigator.of(context).pop();
          messenger.showSnackBar(const SnackBar(content: Text('PIN changed')));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Something went wrong. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['Current PIN', 'New PIN', 'Confirm new PIN'];
    final subtitles = [
      'Enter your current PIN to continue.',
      'Choose a new $pinLength-digit PIN.',
      'Enter the new PIN again.',
    ];
    return _PinScaffold(
      title: titles[_stage],
      subtitle: subtitles[_stage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PinField(
            key: ValueKey(_stage),
            enabled: !_busy,
            errorText: _error,
            onCompleted: _onPin,
          ),
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
