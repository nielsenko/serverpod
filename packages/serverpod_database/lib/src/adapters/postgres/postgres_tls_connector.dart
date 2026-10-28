import 'package:postgres/postgres.dart' as pg;

/// Opens TLS connections to Postgres in place of package:postgres's
/// SecureSocket upgrade, such as postgres_tls's `nativeTlsConnector`.
///
/// Used when the database config sets `requireSsl`. Set it before
/// constructing `Serverpod`, which creates the connection pool.
pg.TlsConnector? postgresTlsConnector;
