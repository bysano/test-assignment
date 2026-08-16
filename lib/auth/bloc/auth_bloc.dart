import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../data/api/api_exception.dart';
import '../auth_repository.dart';

part 'auth_event.dart';
part 'auth_state.dart';

/// Owns whether the app is showing the login screen or the watchlist.
///
/// Only the *initial* login goes through here. Once a session exists, token
/// expiry is handled invisibly by [AuthRepository] on the feed's behalf; this
/// bloc hears about it again only when renewal is no longer possible.
@injectable
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc(this._repository) : super(const AuthChecking()) {
    on<AuthRestoreRequested>(_onRestoreRequested);
    on<AuthLoginRequested>(_onLoginRequested);
    on<AuthLogoutRequested>(_onLogoutRequested);
    on<AuthSessionExpired>(_onSessionExpired);
  }

  final AuthRepository _repository;

  Future<void> _onRestoreRequested(
    AuthRestoreRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthChecking());
    final restored = await _repository.restore();
    emit(restored ? const AuthAuthenticated() : const AuthUnauthenticated());
  }

  Future<void> _onLoginRequested(
    AuthLoginRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthAuthenticating());
    try {
      await _repository.signIn(
        username: event.username,
        password: event.password,
      );
      emit(const AuthAuthenticated());
    } on InvalidCredentialsException {
      emit(const AuthUnauthenticated(message: 'Incorrect username or password.'));
    } on ApiException {
      emit(const AuthUnauthenticated(message: 'The server rejected the sign-in.'));
    } catch (_) {
      // Almost always the feed server not running yet — worth saying plainly
      // rather than as a stack trace.
      emit(
        const AuthUnauthenticated(
          message: 'Could not reach the feed server. Is it running?',
        ),
      );
    }
  }

  Future<void> _onLogoutRequested(
    AuthLogoutRequested event,
    Emitter<AuthState> emit,
  ) async {
    await _repository.signOut();
    emit(const AuthUnauthenticated());
  }

  Future<void> _onSessionExpired(
    AuthSessionExpired event,
    Emitter<AuthState> emit,
  ) async {
    await _repository.signOut();
    emit(AuthUnauthenticated(message: event.message));
  }
}
