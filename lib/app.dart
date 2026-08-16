import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'auth/bloc/auth_bloc.dart';
import 'auth/view/login_page.dart';
import 'core/theme.dart';
import 'di/injection.dart';
import 'watchlist/view/watchlist_page.dart';

class PulseApp extends StatelessWidget {
  const PulseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<AuthBloc>(
      create: (_) => getIt<AuthBloc>()..add(const AuthRestoreRequested()),
      child: MaterialApp(
        title: 'Pulse',
        debugShowCheckedModeBanner: false,
        theme: buildPulseTheme(),
        home: const _AuthGate(),
      ),
    );
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthState>(
      builder: (context, state) => switch (state) {
        AuthChecking() => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
        // Keyed so signing out disposes the watchlist bloc and its feed rather
        // than handing a new session the previous one's connection.
        AuthAuthenticated() => const WatchlistPage(key: ValueKey('watchlist')),
        AuthAuthenticating() || AuthUnauthenticated() => const LoginPage(),
      },
    );
  }
}
