/// The outcome of one of [RunnerApi]'s migration commands.
///
/// Carries no instruction for retrying past warnings: the way to pass `force`
/// differs per surface (`⇧+M` in the terminal UI, `force: true` over MCP), so
/// [abortedForWarnings] says *that* confirmation is missing and each surface
/// words the retry itself.
class MigrationResult {
  const MigrationResult({
    required this.message,
    this.isError = false,
    this.abortedForWarnings = false,
    this.created = false,
  });

  /// Human-readable description of what happened.
  final String message;

  /// Whether the command failed.
  final bool isError;

  /// Whether the command failed only because warnings were present and `force`
  /// was not given.
  ///
  /// The runner never prompts, so a caller that wants to go ahead anyway asks
  /// its own user and calls again with `force: true`.
  final bool abortedForWarnings;

  /// Whether a migration was written to disk, so a caller can suggest applying
  /// it.
  final bool created;

  Map<String, Object?> toJson() => {
    'message': message,
    'isError': isError,
    'abortedForWarnings': abortedForWarnings,
    'created': created,
  };

  static MigrationResult fromJson(Map<String, Object?> json) => MigrationResult(
    message: json['message'] as String? ?? '',
    isError: json['isError'] as bool? ?? false,
    abortedForWarnings: json['abortedForWarnings'] as bool? ?? false,
    created: json['created'] as bool? ?? false,
  );
}
