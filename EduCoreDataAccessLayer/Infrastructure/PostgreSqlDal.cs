using Npgsql;
using NpgsqlTypes;
using System.Data;

namespace EduCoreDataAccessLayer.Infrastructure
{
    public sealed class PostgreSqlDal : IDisposable
    {
        private readonly NpgsqlConnection _connection;
        private bool _disposed;

        public PostgreSqlDal(string connectionString)
        {
            _connection = new NpgsqlConnection(connectionString);
        }

        public async Task<DataSet> ExecuteProcedureWithCursorsAsync(
            string procedureName,
            NpgsqlParameter[] parameters)
        {
            var dataSet = new DataSet();

            if (_connection.State != ConnectionState.Open)
                await _connection.OpenAsync();

            await using var transaction = await _connection.BeginTransactionAsync();

            try
            {
                await using var command = new NpgsqlCommand(procedureName, _connection, transaction);
                command.CommandType = CommandType.StoredProcedure;

                if (parameters != null)
                {
                    foreach (var parameter in parameters)
                    {
                        if (parameter == null) continue;
                        parameter.Value ??= DBNull.Value;
                        command.Parameters.Add(parameter);
                    }
                }

                await command.ExecuteNonQueryAsync();

                var cursorParameters = parameters?
                    .Where(p => p.NpgsqlDbType == NpgsqlDbType.Refcursor)
                    .ToList();

                if (cursorParameters != null)
                {
                    foreach (var cursorParam in cursorParameters)
                    {
                        var cursorName = cursorParam.Value?.ToString();

                        if (string.IsNullOrWhiteSpace(cursorName))
                            throw new Exception($"Cursor name is missing for parameter '{cursorParam.ParameterName}'");

                        await using var fetchCommand = new NpgsqlCommand(
                            $"FETCH ALL IN \"{cursorName}\";",
                            _connection,
                            transaction
                        );

                        using var adapter = new NpgsqlDataAdapter(fetchCommand);
                        var table = new DataTable();
                        adapter.Fill(table);

                        dataSet.Tables.Add(table);
                    }
                }

                await transaction.CommitAsync();
                return dataSet;
            }
            catch
            {
                await transaction.RollbackAsync();
                throw;
            }
            finally
            {
                await _connection.CloseAsync();
            }
        }

        public async Task<int> ExecuteNonQueryProcedureAsync(
            string procedureName,
            NpgsqlParameter[] parameters)
        {
            if (_connection.State != ConnectionState.Open)
                await _connection.OpenAsync();

            await using var transaction = await _connection.BeginTransactionAsync();

            try
            {
                await using var command = new NpgsqlCommand(procedureName, _connection, transaction);
                command.CommandType = CommandType.StoredProcedure;

                if (parameters != null)
                {
                    foreach (var parameter in parameters)
                    {
                        if (parameter == null) continue;
                        parameter.Value ??= DBNull.Value;
                        command.Parameters.Add(parameter);
                    }
                }

                var result = await command.ExecuteNonQueryAsync();
                await transaction.CommitAsync();
                return result;
            }
            catch
            {
                await transaction.RollbackAsync();
                throw;
            }
            finally
            {
                await _connection.CloseAsync();
            }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _connection.Dispose();
            _disposed = true;
            GC.SuppressFinalize(this);
        }
    }
}
