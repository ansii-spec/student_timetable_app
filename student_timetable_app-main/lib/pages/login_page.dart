import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'timetable_home_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static const String _allowedDomain = 'pwr.nu.edu.pk';
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: <String>['email'],
    hostedDomain: _allowedDomain,
  );

  bool _isSigningIn = false;

  String _extractRollNumber(String email) {
    final String localPart = email.split('@').first.trim().toLowerCase();

    // Already in roll-number format, e.g. 23P-3063
    final RegExp formattedPattern = RegExp(r'^\d{2}[a-z]-\d{4}$');
    if (formattedPattern.hasMatch(localPart)) {
      return localPart.toUpperCase();
    }

    // FAST-style email local part, e.g. p233063 -> 23P-3063
    final RegExp fastEmailPattern = RegExp(r'^p(\d{6})$');
    final RegExpMatch? match = fastEmailPattern.firstMatch(localPart);
    if (match != null) {
      final String digits = match.group(1)!;
      final String batch = digits.substring(0, 2);
      final String serial = digits.substring(2, 6);
      return '${batch}P-$serial';
    }

    return localPart.toUpperCase();
  }

  Future<void> _continueWithGoogle() async {
    setState(() {
      _isSigningIn = true;
    });

    try {
      final GoogleSignInAccount? account = await _googleSignIn.signIn();

      if (!mounted || account == null) {
        return;
      }

      final String email = account.email.toLowerCase().trim();
      final bool isAllowed = email.endsWith('@$_allowedDomain');

      if (!isAllowed) {
        await _googleSignIn.signOut();
        if (!mounted) {
          return;
        }
        _showMessage(
          'Only @$_allowedDomain accounts are allowed. You selected $email.',
          isError: true,
        );
        return;
      }

      if (!mounted) {
        return;
      }
      final String userName = (account.displayName ?? '').trim().isNotEmpty
          ? account.displayName!.trim()
          : 'Student';
      final String rollNumber = _extractRollNumber(email);

      _showMessage('Login successful for $email');
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => TimetableHomePage(
            userEmail: email,
            userName: userName,
            photoUrl: account.photoUrl,
            rollNumber: rollNumber,
            onLogout: () async {
              await _googleSignIn.signOut();
              if (!mounted) {
                return;
              }
              Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(
                  builder: (_) => const LoginPage(),
                ),
              );
            },
          ),
        ),
      );
    } on PlatformException catch (e) {
      if (!mounted) {
        return;
      }
      _showMessage(
        'Google sign-in failed (${e.code}): ${e.message ?? 'No details'}',
        isError: true,
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      _showMessage(
        'Google sign-in failed: $e',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSigningIn = false;
        });
      }
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Colors.red : Colors.green,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Icon(Icons.calendar_month, size: 72),
                const SizedBox(height: 16),
                const Text(
                  'Student Timetable',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Sign in with your university Google account',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isSigningIn ? null : _continueWithGoogle,
                    icon: _isSigningIn
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: Text(
                      _isSigningIn
                          ? 'Signing in...'
                          : 'Continue with Google',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
