import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';

/// True when [email] appears in the `superadmin` node value (a string, list or
/// map of emails).
bool isSuperAdminEmail(Object? node, String? email) {
  if (email == null) return false;
  final target = email.trim().toLowerCase();
  bool matches(Object? v) => v is String && v.trim().toLowerCase() == target;
  if (node is Map) return node.values.any(matches);
  if (node is List) return node.any(matches);
  return matches(node);
}

/// Whether the currently signed-in user is listed under the `superadmin` node.
Future<bool> currentUserIsSuperAdmin() async {
  try {
    final email = FirebaseAuth.instance.currentUser?.email;
    final snapshot = await FirebaseDatabase.instance
        .ref('superadmin')
        .get()
        .timeout(const Duration(seconds: 10));
    return isSuperAdminEmail(snapshot.value, email);
  } catch (_) {
    return false;
  }
}

/// Creates a new user account. Only available to the super admin (listed under
/// the `superadmin` node), who must re-enter their password to confirm.
///
/// A temporary secondary Firebase app is used so the current app session is
/// never changed while verifying the super admin or creating the account.
class CreateAccountPage extends StatefulWidget {
  const CreateAccountPage({super.key});

  @override
  State<CreateAccountPage> createState() => _CreateAccountPageState();
}

class _CreateAccountPageState extends State<CreateAccountPage> {
  static const _tempAppName = 'account-creation';

  final _formKey = GlobalKey<FormState>();
  final _adminEmail = TextEditingController();
  final _adminPassword = TextEditingController();
  final _newEmail = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();

  bool _loading = false;
  bool _obscureAdmin = true;
  bool _obscureNew = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _adminEmail.text = FirebaseAuth.instance.currentUser?.email ?? '';
  }

  @override
  void dispose() {
    _adminEmail.dispose();
    _adminPassword.dispose();
    _newEmail.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<FirebaseApp> _tempApp() async {
    try {
      return await Firebase.initializeApp(
        name: _tempAppName,
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } on FirebaseException catch (e) {
      if (e.code == 'duplicate-app') return Firebase.app(_tempAppName);
      rethrow;
    }
  }

  Future<void> _create() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    FirebaseApp? app;
    try {
      app = await _tempApp();
      final auth = FirebaseAuth.instanceFor(app: app);
      final db = FirebaseDatabase.instanceFor(app: app);

      // 1. Authenticate the super admin.
      final admin = await auth.signInWithEmailAndPassword(
        email: _adminEmail.text.trim(),
        password: _adminPassword.text,
      );

      // 2. Confirm that account is listed under the `superadmin` node.
      final snapshot = await db.ref('superadmin').get();
      if (!isSuperAdminEmail(snapshot.value, admin.user?.email)) {
        await auth.signOut();
        throw _AccountError('That account is not authorized to create users.');
      }

      // 3. Create the new account, then discard the temporary session.
      await auth.createUserWithEmailAndPassword(
        email: _newEmail.text.trim(),
        password: _newPassword.text,
      );
      await auth.signOut();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Account created for ${_newEmail.text.trim()}')),
      );
      Navigator.of(context).pop();
    } on _AccountError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _error = _authMessage(e));
    } on FirebaseException catch (e) {
      if (mounted) {
        setState(
          () => _error = e.code == 'permission-denied'
              ? 'Cannot read the superadmin record. Check database rules.'
              : 'Database error: ${e.message ?? e.code}',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Something went wrong. Please try again.');
      }
    } finally {
      try {
        await app?.delete();
      } catch (_) {}
      if (mounted) setState(() => _loading = false);
    }
  }

  String _authMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Super admin email or password is incorrect.';
      case 'email-already-in-use':
        return 'An account with that email already exists.';
      case 'weak-password':
        return 'New password is too weak (minimum 6 characters).';
      case 'too-many-requests':
        return 'Too many attempts. Try again later.';
      case 'network-request-failed':
        return 'Network error. Check your connection.';
      default:
        return 'Could not create the account. Please try again.';
    }
  }

  InputDecoration _decoration(String label, IconData icon, {Widget? suffix}) =>
      InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        prefixIcon: Icon(icon),
        suffixIcon: suffix,
      );

  Widget _eye(bool obscure, VoidCallback toggle) => IconButton(
    tooltip: obscure ? 'Show password' : 'Hide password',
    icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
    onPressed: toggle,
  );

  String? _requireEmail(String? v) =>
      (v == null || !v.contains('@')) ? 'Enter a valid email' : null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create account'),
        backgroundColor: const Color(0xFF205D36),
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Super admin authorization',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _adminEmail,
                      readOnly: true,
                      enabled: !_loading,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      decoration: _decoration(
                        'Super admin email',
                        Icons.admin_panel_settings_outlined,
                      ),
                      validator: _requireEmail,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _adminPassword,
                      enabled: !_loading,
                      obscureText: _obscureAdmin,
                      textInputAction: TextInputAction.next,
                      decoration: _decoration(
                        'Super admin password',
                        Icons.lock_outline,
                        suffix: _eye(
                          _obscureAdmin,
                          () => setState(() => _obscureAdmin = !_obscureAdmin),
                        ),
                      ),
                      validator: (v) => (v == null || v.isEmpty)
                          ? 'Enter the super admin password'
                          : null,
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'New account',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _newEmail,
                      enabled: !_loading,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      decoration: _decoration('Email', Icons.email_outlined),
                      validator: _requireEmail,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _newPassword,
                      enabled: !_loading,
                      obscureText: _obscureNew,
                      textInputAction: TextInputAction.next,
                      decoration: _decoration(
                        'Password',
                        Icons.lock_outline,
                        suffix: _eye(
                          _obscureNew,
                          () => setState(() => _obscureNew = !_obscureNew),
                        ),
                      ),
                      validator: (v) => (v == null || v.length < 6)
                          ? 'Use at least 6 characters'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _confirmPassword,
                      enabled: !_loading,
                      obscureText: _obscureNew,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _create(),
                      decoration: _decoration(
                        'Confirm password',
                        Icons.lock_outline,
                      ),
                      validator: (v) => v != _newPassword.text
                          ? 'Passwords do not match'
                          : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: const TextStyle(color: Color(0xFFB00020)),
                      ),
                    ],
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: _loading ? null : _create,
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Create account'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountError implements Exception {
  _AccountError(this.message);
  final String message;
}
