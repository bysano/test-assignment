part of 'auth_bloc.dart';

sealed class AuthEvent extends Equatable {
  const AuthEvent();

  @override
  List<Object?> get props => [];
}

/// App start: look for a still-valid session in secure storage.
final class AuthRestoreRequested extends AuthEvent {
  const AuthRestoreRequested();
}

final class AuthLoginRequested extends AuthEvent {
  const AuthLoginRequested({required this.username, required this.password});

  final String username;
  final String password;

  @override
  List<Object?> get props => [username, password];
}

final class AuthLogoutRequested extends AuthEvent {
  const AuthLogoutRequested();
}

/// The feed could not re-authenticate on its own, so the user has to.
final class AuthSessionExpired extends AuthEvent {
  const AuthSessionExpired(this.message);

  final String message;

  @override
  List<Object?> get props => [message];
}
