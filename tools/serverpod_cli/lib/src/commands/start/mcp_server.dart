import 'package:dart_mcp/server.dart';
import 'package:serverpod_cli/src/generated/version.dart';

/// MCP server that exposes serverpod dev tools.
///
/// Runs inside the CLI process during watch mode, letting AI agents trigger
/// operations that require explicit intent (like applying migrations).
base class ServerpodMcpServer extends MCPServer with ToolsSupport {
  /// Callback to apply pending database migrations.
  Future<void> Function()? onApplyMigration;

  ServerpodMcpServer(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(
          name: 'serverpod',
          version: templateVersion,
        ),
        instructions:
            'MCP server inside the Serverpod CLI, active during `serverpod start --watch`. '
            "Exposes tools for operations that require the CLI process's internal state.",
      ) {
    registerTool(_applyMigrationTool, _applyMigration);
  }

  static final _applyMigrationTool = Tool(
    name: 'apply_migration',
    description:
        'Apply pending database migrations. Restarts the server with --apply-migrations.',
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
                'Migration applied. Server restarted with --apply-migrations.',
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
