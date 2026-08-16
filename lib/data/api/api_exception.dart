/// The server rejected our token — it expired, or was never valid.
///
/// Distinct from [InvalidCredentialsException]: this one is recoverable by
/// re-logging-in behind the user's back, and the feed does exactly that.
final class UnauthorizedException implements Exception {
  const UnauthorizedException();

  @override
  String toString() => 'UnauthorizedException: token rejected';
}

/// `/login` rejected the username or password. Not recoverable without the
/// user, so it is the one auth failure that surfaces in the UI.
final class InvalidCredentialsException implements Exception {
  const InvalidCredentialsException();

  @override
  String toString() => 'InvalidCredentialsException';
}

/// Any other unhappy response.
final class ApiException implements Exception {
  const ApiException(this.statusCode, [this.body]);

  final int statusCode;
  final String? body;

  @override
  String toString() => 'ApiException($statusCode)${body == null ? '' : ': $body'}';
}
