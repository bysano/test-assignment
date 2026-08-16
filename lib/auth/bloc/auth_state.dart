part of 'auth_bloc.dart';

sealed class AuthState extends Equatable {
  const AuthState();

  @override
  List<Object?> get props => [];
}

/// Before the stored session has been looked at.
final class AuthChecking extends AuthState {
  const AuthChecking();
}

final class AuthUnauthenticated extends AuthState {
  const AuthUnauthenticated({this.message});

  /// Why the user is looking at a login screen, when there is a reason worth
  /// showing — bad credentials, or a session that could not be renewed.
  final String? message;

  @override
  List<Object?> get props => [message];
}

final class AuthAuthenticating extends AuthState {
  const AuthAuthenticating();
}

final class AuthAuthenticated extends AuthState {
  const AuthAuthenticated();
}
