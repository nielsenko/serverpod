import 'package:dart_mcp/server.dart';

/// MCP server that exposes serverpod dev tools.
///
/// Runs inside the CLI process during watch mode, letting AI agents trigger
/// operations that require explicit intent (like applying migrations).
base class ServerpodMcpServer extends MCPServer with ToolsSupport {
  /// Callback to apply pending database migrations.
  Future<void> Function()? onApplyMigration;

  ServerpodMcpServer(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(name: 'serverpod', version: '0.1.0'),
        instructions:
            'Serverpod dev server. Use the apply_migration tool to apply '
            'pending database migrations. The server will restart with '
            '--apply-migrations and then clear the flag for subsequent '
            'hot reloads.',
      ) {
    registerTool(_applyMigrationTool, _applyMigration);
  }

  static final _applyMigrationTool = Tool(
    name: 'apply_migration',
    description:
        'Apply pending database migrations. Restarts the server with '
        '--apply-migrations (one-shot - subsequent reloads will not '
        're-apply).',
    inputSchema: Schema.object(),
  );

  Future<CallToolResult> _applyMigration(CallToolRequest request) async {
    final callback = onApplyMigration;
    if (callback == null) {
      return CallToolResult(
        content: [TextContent(text: 'Watch session not connected.')],
        isError: true,
      );
    }

    try {
      await callback();
      return CallToolResult(
        content: [
          TextContent(
            text:
                'Migration applied. Server restarted with '
                '--apply-migrations.',
          ),
        ],
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Failed to apply migration: $e')],
        isError: true,
      );
    }
  }
}
