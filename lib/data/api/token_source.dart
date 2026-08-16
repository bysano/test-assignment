/// Supplies bearer tokens to anything that talks to the server.
///
/// Lives in the API layer rather than the auth layer on purpose: the
/// interceptors depend on *this*, not on [AuthRepository], so the dependency
/// runs auth → api and never back again.
abstract interface class TokenSource {
  /// A token believed valid, renewed transparently if it is at or near expiry.
  Future<String> currentToken();

  /// A token guaranteed to be different from [rejected].
  ///
  /// Takes the rejected token rather than nothing so that a burst of 401s
  /// costs **one** login rather than one each: whoever gets here first
  /// replaces the token, and everyone arriving afterwards with the same dead
  /// token is simply handed the replacement.
  ///
  /// Throws [InvalidCredentialsException] when no new token can be obtained —
  /// the one auth failure that needs the user.
  Future<String> refreshAfter(String rejected);
}
