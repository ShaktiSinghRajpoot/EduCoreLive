using EduCoreDataAccessLayer.Infrastructure;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Options;
using Npgsql;
using NpgsqlTypes;
using System.Data;

namespace educore.Services
{
    public interface IBaseService
    {
        //Tuple<string, string, string, int, int, int, string> GetServerDate();

        public Task<List<SelectListItem>> GetSelectListAsync(string usp, string activity, string param1 = "", string param2 = "");

        //bool IsRecordAlreadyExist(string usp, string activity, string param1 = "", string param2 = "");
    }

    public class BaseService : IBaseService
    {
        private readonly PgExec _db;
        // string ModelId;
        public BaseService(PgExec db)
        {
            _db = db;
        }

        //public Tuple<string, string, string, int, int, int, string> GetServerDate()
        //{
        //    var data = new Tuple<string, string, string, int, int, int, string>("", "", "", 0, 0, 0, "");
        //    SqlConnection con = new SqlConnection(_connectionStrings.Connection);
        //    SqlCommand cmd = new SqlCommand(Usp.BasicInfo, con);
        //    try
        //    {
        //        cmd.CommandType = CommandType.StoredProcedure;
        //        cmd.Parameters.AddWithValue("@Activity", "GetServerDateTime");

        //        cmd.Parameters.Add("Msg", SqlDbType.VarChar, 500);
        //        cmd.Parameters["Msg"].Direction = ParameterDirection.Output;
        //        cmd.Parameters.Add("Flag", SqlDbType.Int, 10);
        //        cmd.Parameters["Flag"].Direction = ParameterDirection.Output;

        //        con.Open();
        //        SqlDataReader dr = cmd.ExecuteReader();
        //        while (dr.Read())
        //        {
        //            data = new Tuple<string, string, string, int, int, int, string>(
        //                dr["CurrentDate"].ToString(),
        //                dr["CurrentDateTime"].ToString(),
        //                dr["CurrentTime"].ToString(),
        //                Convert.ToInt32(dr["CurrentDay"]),
        //                Convert.ToInt32(dr["CurrentMonth"]),
        //                Convert.ToInt32(dr["CurrentYear"]),
        //                dr["CurrentMonthYear"].ToString());
        //        }
        //        con.Close();
        //    }
        //    catch (Exception exception)
        //    {
        //        _ = exception;
        //    }
        //    finally
        //    {
        //        if (con.State == ConnectionState.Open) { con.Close(); }
        //        cmd.Dispose();
        //    }
        //    return data;
        //}

        public async Task<List<SelectListItem>> GetSelectListAsync(string procedureName, string activity, string param1 = "", string param2 = "")
        {
            var list = new List<SelectListItem>();

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_activity", activity),
                new NpgsqlParameter("p_param1", param1),
                new NpgsqlParameter("p_param2", param2),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "dropdown_cursor" }
            };

            var dal = _db;

            var ds = await dal.ExecuteProcedureWithCursorsAsync(
                procedureName,
                parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return list;

            bool hasSelected = ds.Tables[0].Columns.Contains("IsSelected");

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                list.Add(new SelectListItem
                {
                    Text = row["Name"]?.ToString() ?? string.Empty,
                    Value = row["Code"]?.ToString() ?? string.Empty,
                    Selected = hasSelected && row["IsSelected"] != DBNull.Value && Convert.ToBoolean(row["IsSelected"])
                });
            }

            return list;
        }

    }
}