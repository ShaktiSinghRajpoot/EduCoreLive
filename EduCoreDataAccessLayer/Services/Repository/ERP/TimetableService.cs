using System.Data;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class TimetableService : ITimetableService
    {
        private readonly PgExec _db;
        private const string Sp = "academic.sp_school_admin_timetable_manage";

        public TimetableService(PgExec db)
        {
            _db = db;
        }

        public async Task<TimetableSetup> GetSetupAsync(
            int tenantId, int schoolId, int actionUserId, int academicYearId = 0)
        {
            var setup = new TimetableSetup();
            if (tenantId <= 1 || schoolId <= 0) return setup;

            var p = Params("GetSetup", tenantId, schoolId, actionUserId);
            if (academicYearId > 0) p[4].Value = academicYearId;   // p_academic_year_id

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
            if (ds.Tables.Count == 0) return setup;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                setup.Periods.Add(new TimetablePeriod
                {
                    PeriodSeq  = IntVal(row, "period_seq"),
                    Label      = Str(row, "label"),
                    PeriodType = Str(row, "period_type"),
                    StartTime  = Str(row, "start_time"),
                    EndTime    = Str(row, "end_time")
                });
            }

            if (ds.Tables.Count > 1)
                foreach (DataRow row in ds.Tables[1].Rows)
                    setup.Sections.Add(new TimetableSection
                    {
                        SectionId   = IntVal(row, "section_id"),
                        ClassName   = Str(row, "class_name"),
                        SectionName = Str(row, "section_name"),
                        Label       = Str(row, "label"),
                        RoomNo      = Str(row, "room_no")
                    });

            if (ds.Tables.Count > 2)
                foreach (DataRow row in ds.Tables[2].Rows)
                    setup.Teachers.Add(new TimetableTeacher
                    {
                        StaffId  = IntVal(row, "staff_id"),
                        FullName = Str(row, "full_name")
                    });

            if (ds.Tables.Count > 3)
                foreach (DataRow row in ds.Tables[3].Rows)
                    setup.Days.Add(new TimetableDay
                    {
                        DayOfWeek = IntVal(row, "day_of_week"),
                        DayLabel  = Str(row, "day_label")
                    });

            return setup;
        }

        public async Task<TimetableGrid> GetGridAsync(int sectionId, int tenantId, int schoolId, int actionUserId)
        {
            var grid = new TimetableGrid();
            if (tenantId <= 1 || schoolId <= 0 || sectionId <= 0) return grid;

            var p = Params("GetGrid", tenantId, schoolId, actionUserId);
            p[5].Value = sectionId;       // p_section_id

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
            if (ds.Tables.Count == 0) return grid;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                grid.Entries.Add(new TimetableEntry
                {
                    DayOfWeek   = IntVal(row, "day_of_week"),
                    PeriodSeq   = IntVal(row, "period_seq"),
                    SubjectId   = IntVal(row, "subject_id"),
                    SubjectName = Str(row, "subject_name"),
                    StaffId     = NullInt(row, "staff_id"),
                    StaffName   = Str(row, "staff_name"),
                    RoomNo      = Str(row, "room_no")
                });
            }

            if (ds.Tables.Count > 1)
                foreach (DataRow row in ds.Tables[1].Rows)
                    grid.Busy.Add(new TimetableBusy
                    {
                        DayOfWeek    = IntVal(row, "day_of_week"),
                        PeriodSeq    = IntVal(row, "period_seq"),
                        StaffId      = IntVal(row, "staff_id"),
                        SectionLabel = Str(row, "section_label")
                    });

            if (ds.Tables.Count > 2)
                foreach (DataRow row in ds.Tables[2].Rows)
                    grid.Subjects.Add(new SubjectItem
                    {
                        SubjectId   = IntVal(row, "subject_id"),
                        SubjectName = Str(row, "subject_name")
                    });

            return grid;
        }

        public async Task<List<TimetableTeacherEntry>> GetTeacherGridAsync(
            int staffId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<TimetableTeacherEntry>();
            if (tenantId <= 1 || schoolId <= 0 || staffId <= 0) return list;

            var p = Params("GetTeacherGrid", tenantId, schoolId, actionUserId);
            p[9].Value = staffId;         // p_staff_id

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
            if (ds.Tables.Count == 0) return list;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                list.Add(new TimetableTeacherEntry
                {
                    DayOfWeek    = IntVal(row, "day_of_week"),
                    PeriodSeq    = IntVal(row, "period_seq"),
                    SubjectId    = IntVal(row, "subject_id"),
                    SubjectName  = Str(row, "subject_name"),
                    SectionLabel = Str(row, "section_label"),
                    RoomNo       = Str(row, "room_no")
                });
            }
            return list;
        }

        public async Task<TimetableSaveResult> SaveCellAsync(
            int sectionId, int day, int periodSeq, int subjectId, int? staffId, string? roomNo,
            int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || sectionId <= 0)
                return new TimetableSaveResult { Message = "Invalid section." };
            if (subjectId <= 0)
                return new TimetableSaveResult { Message = "Pick a subject." };

            var p = Params("SaveCell", tenantId, schoolId, actionUserId);
            p[5].Value = sectionId;                                     // p_section_id
            p[6].Value = (short)day;                                    // p_day
            p[7].Value = (short)periodSeq;                              // p_period_seq
            p[8].Value = subjectId;                                     // p_subject_id
            p[9].Value = staffId is > 0 ? staffId.Value : DBNull.Value; // p_staff_id
            p[10].Value = (object?)roomNo ?? DBNull.Value;              // p_room_no

            return await RunWriteAsync(p, "Period updated.");
        }

        public async Task<TimetableSaveResult> ClearCellAsync(
            int sectionId, int day, int periodSeq, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || sectionId <= 0)
                return new TimetableSaveResult { Message = "Invalid section." };

            var p = Params("ClearCell", tenantId, schoolId, actionUserId);
            p[5].Value = sectionId;
            p[6].Value = (short)day;
            p[7].Value = (short)periodSeq;

            return await RunWriteAsync(p, "Period cleared.");
        }

        public async Task<TimetableSaveResult> CopyDayAsync(
            int sectionId, int fromDay, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || sectionId <= 0)
                return new TimetableSaveResult { Message = "Invalid section." };

            var p = Params("CopyDay", tenantId, schoolId, actionUserId);
            p[5].Value = sectionId;
            p[6].Value = (short)fromDay;

            return await RunWriteAsync(p, "Day copied.");
        }

        private async Task<TimetableSaveResult> RunWriteAsync(NpgsqlParameter[] p, string fallbackMessage)
        {
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new TimetableSaveResult { Message = "Nothing changed." };

                var row = ds.Tables[0].Rows[0];
                return new TimetableSaveResult
                {
                    Success = Has(row, "success") && row["success"] != DBNull.Value && Convert.ToBoolean(row["success"]),
                    Message = string.IsNullOrEmpty(Str(row, "message")) ? fallbackMessage : Str(row, "message"),
                    Copied  = IntVal(row, "copied"),
                    Skipped = IntVal(row, "skipped")
                };
            }
            catch (PostgresException ex)
            {
                // Proc RAISE — the teacher clash and "not a teaching period" land here.
                return new TimetableSaveResult { Message = ex.MessageText };
            }
        }

        // Fixed positional layout matching sp_school_admin_timetable_manage.
        private static NpgsqlParameter[] Params(string operation, int tenantId, int schoolId, int actionUserId)
        {
            return new NpgsqlParameter[]
            {
                new("p_operation",        NpgsqlDbType.Varchar)  { Value = operation },
                new("p_tenant_id",        NpgsqlDbType.Integer)  { Value = tenantId },
                new("p_school_id",        NpgsqlDbType.Integer)  { Value = schoolId },
                new("p_action_user_id",   NpgsqlDbType.Integer)  { Value = actionUserId },
                new("p_academic_year_id", NpgsqlDbType.Integer)  { Value = DBNull.Value },
                new("p_section_id",       NpgsqlDbType.Integer)  { Value = DBNull.Value },
                new("p_day",              NpgsqlDbType.Smallint) { Value = DBNull.Value },
                new("p_period_seq",       NpgsqlDbType.Smallint) { Value = DBNull.Value },
                new("p_subject_id",       NpgsqlDbType.Integer)  { Value = DBNull.Value },
                new("p_staff_id",         NpgsqlDbType.Integer)  { Value = DBNull.Value },
                new("p_room_no",          NpgsqlDbType.Varchar)  { Value = DBNull.Value },
                new("p_result",  NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "timetable_cursor" },
                new("p_result2", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "timetable_cursor2" },
                new("p_result3", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "timetable_cursor3" },
                new("p_result4", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "timetable_cursor4" }
            };
        }

        private static bool Has(DataRow r, string col) => r.Table.Columns.Contains(col);
        private static int  IntVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col]) : 0;
        private static int? NullInt(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col]) : null;
        private static string Str(DataRow r, string col)   => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString()! : string.Empty;
    }
}
