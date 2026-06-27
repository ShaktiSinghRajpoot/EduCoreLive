using Npgsql;
using NpgsqlTypes;
using System.Data;

namespace EduCoreDataAccessLayer.Infrastructure
{
    /// <summary>
    /// Fully-async, reader-based replacement for the DataSet/DataAdapter DAL (PostgreSqlDal).
    ///
    /// WHY this exists (Fix #2 + #7):
    ///  - PostgreSqlDal used NpgsqlDataAdapter.Fill(...), which is SYNCHRONOUS — it blocks a
    ///    worker thread for the whole DB fetch (thread-pool starvation under load) and buffers
    ///    every result set twice (DataSet, then our List&lt;T&gt;).
    ///  - PgExec uses ExecuteReaderAsync + ReadAsync and streams rows straight into the caller's
    ///    list: no thread blocking, one copy instead of two.
    ///  - It takes a singleton <see cref="NpgsqlDataSource"/> (Fix #7) instead of building a new
    ///    connection string per call — better pooling and one place to tune.
    /// </summary>
    public sealed class PgExec
    {
        private readonly NpgsqlDataSource _dataSource;

        public PgExec(NpgsqlDataSource dataSource) => _dataSource = dataSource;

        /// <summary>
        /// Calls a proc that returns one or more refcursors. For each refcursor parameter (in the
        /// order they appear in <paramref name="parameters"/>), the mapper at the same index is
        /// invoked with an open async reader positioned before the first row. Pass <c>null</c> to
        /// skip a cursor. The connection + transaction stay open for the whole read, then commit.
        /// </summary>
        public async Task ExecuteCursorsAsync(string procedureName, NpgsqlParameter[] parameters, params Func<NpgsqlDataReader, Task>?[] cursorMappers)
        {
            await using var conn = await _dataSource.OpenConnectionAsync();
            // WHY: Postgres refcursors are only valid INSIDE the transaction that opened them,
            // so the FETCH must run in the same transaction as the CALL.
            await using var tx = await conn.BeginTransactionAsync();
            try
            {
                await using (var cmd = new NpgsqlCommand(procedureName, conn, tx) { CommandType = CommandType.StoredProcedure })
                {
                    AddParameters(cmd, parameters);
                    await cmd.ExecuteNonQueryAsync();
                }

                var cursors = parameters?
                    .Where(p => p != null && p.NpgsqlDbType == NpgsqlDbType.Refcursor)
                    .ToList() ?? new List<NpgsqlParameter>();

                for (int i = 0; i < cursors.Count; i++)
                {
                    var mapper = i < cursorMappers.Length ? cursorMappers[i] : null;
                    if (mapper == null) continue;   // caller doesn't want this cursor

                    var cursorName = cursors[i].Value?.ToString();
                    if (string.IsNullOrWhiteSpace(cursorName))
                        throw new InvalidOperationException($"Cursor name is missing for parameter '{cursors[i].ParameterName}'.");

                    await using var fetch = new NpgsqlCommand($"FETCH ALL IN \"{cursorName}\";", conn, tx);
                    await using var reader = await fetch.ExecuteReaderAsync();
                    await mapper(reader);
                }

                await tx.CommitAsync();
            }
            catch
            {
                await tx.RollbackAsync();
                throw;
            }
        }

        /// <summary>
        /// Drop-in async replacement for the old PostgreSqlDal.ExecuteProcedureWithCursorsAsync:
        /// returns each refcursor as a <see cref="DataTable"/> in a <see cref="DataSet"/>, but fills
        /// it via <c>ExecuteReaderAsync</c>/<c>ReadAsync</c> instead of the synchronous
        /// <c>NpgsqlDataAdapter.Fill</c>. Lets services keep their existing DataRow mapping while
        /// still getting the async (no thread-block) + singleton-data-source benefits.
        /// </summary>
        public async Task<DataSet> ExecuteProcedureWithCursorsAsync(string procedureName, NpgsqlParameter[] parameters)
        {
            var dataSet = new DataSet();

            await using var conn = await _dataSource.OpenConnectionAsync();
            await using var tx = await conn.BeginTransactionAsync();
            try
            {
                await using(
                  var command = new NpgsqlCommand(procedureName, conn, tx)
                  {
                   CommandType = CommandType.StoredProcedure
                  }
                )
                {
                    AddParameters(command, parameters);
                    await command.ExecuteNonQueryAsync();
                }
                var cursors = parameters?.Where(p => p != null && p.NpgsqlDbType == NpgsqlDbType.Refcursor).ToList() ?? new List<NpgsqlParameter>();
                foreach (var cursor in cursors)
                {
                    var cursorName = cursor.Value?.ToString();
                    if (string.IsNullOrWhiteSpace(cursorName))
                        throw new InvalidOperationException($"Cursor name is missing for parameter '{cursor.ParameterName}'.");

                    await using var fetch = new NpgsqlCommand($"FETCH ALL IN \"{cursorName}\";", conn, tx);
                    await using var reader = await fetch.ExecuteReaderAsync();
                    dataSet.Tables.Add(await ReadTableAsync(reader));
                }
                await tx.CommitAsync();
                return dataSet;
            }
            catch(Exception ex)
            {
                await tx.RollbackAsync();
                throw;
            }
        }

        // Build a DataTable from a reader using async row reads (no synchronous DataAdapter.Fill).
        private static async Task<DataTable> ReadTableAsync(NpgsqlDataReader reader)
        {
            var table = new DataTable();
            for (int i = 0; i < reader.FieldCount; i++)
                table.Columns.Add(reader.GetName(i), reader.GetFieldType(i) ?? typeof(object));

            var values = new object[reader.FieldCount];
            while (await reader.ReadAsync())
            {
                reader.GetValues(values);     // DataRowCollection.Add copies the array, so reuse is safe
                table.Rows.Add(values);
            }
            return table;
        }

        /// <summary>Calls a proc that returns no cursor (e.g. an INSERT/UPDATE log write).</summary>
        public async Task<int> ExecuteNonQueryProcedureAsync(string procedureName, NpgsqlParameter[] parameters)
        {
            await using var conn = await _dataSource.OpenConnectionAsync();
            await using var tx = await conn.BeginTransactionAsync();
            try
            {
                await using var cmd = new NpgsqlCommand(procedureName, conn, tx) { CommandType = CommandType.StoredProcedure };
                AddParameters(cmd, parameters);
                var result = await cmd.ExecuteNonQueryAsync();
                await tx.CommitAsync();
                return result;
            }
            catch
            {
                await tx.RollbackAsync();
                throw;
            }
        }

        private static void AddParameters(NpgsqlCommand cmd, NpgsqlParameter[] parameters)
        {
            if (parameters == null) return;
            foreach (var p in parameters)
            {
                if (p == null) continue;
                p.Value ??= DBNull.Value;   // WHY: null .Value would throw; procs expect DBNull.
                cmd.Parameters.Add(p);
            }
        }
    }
}
