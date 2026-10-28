/// How many statements a Postgres connection sends before the earliest of
/// them has been answered, as package:postgres's
/// `ConnectionSettings.pipelineDepth`. Above 1, statements started without
/// awaiting the previous one go out together.
///
/// Set it before constructing `Serverpod`, which creates the connection pool.
int postgresPipelineDepth = 1;
