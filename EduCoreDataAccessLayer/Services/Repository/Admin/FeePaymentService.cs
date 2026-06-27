using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;
using System.Data;
using System.Text.Json;

namespace EduCoreDataAccessLayer.Services.Repository.Admin
{
    // PILOT for Fix #2 + #7: this service now uses PgExec (async, reader-based) + the injected
    // singleton NpgsqlDataSource, instead of `new PostgreSqlDal(connectionString)` + DataSet.
    // See docs/SCALING-AND-FIXES.md (Part 3) for the what/why. Other services follow this pattern.
    public class FeePaymentService : IFeePaymentService
    {
        private const string SpRegistrationRecord = "core.sp_registration_fee_record";
        private const string SpStudentDues = "core.sp_student_dues_get";
        private const string SpCollect = "core.sp_fee_payment_collect";
        private const string SpHistory = "core.sp_fee_payment_history_get";
        private const string SpReceipt = "core.sp_fee_receipt_get";
        private const string SpCancel = "core.sp_fee_receipt_cancel";
        private const string SpRefundables = "core.sp_student_refundables_get";
        private const string SpRefund = "core.sp_fee_refund_record";
        private const string SpDayCollection = "core.sp_fee_day_collection_get";
        private const string SpDayClose = "core.sp_fee_day_close";
        private const string SpCollectionRegister = "core.sp_fee_collection_register";
        private const string SpDefaulters = "core.sp_fee_defaulters_get";
        private const string SpAdvanceGet = "core.sp_student_advance_get";
        private const string SpConcessionCancel = "core.sp_fee_concession_cancel_register";

        private readonly PgExec _db;
        // WHY: ILogger lets us record WHY a financial operation failed before we map it to a
        // friendly message. Without this, a failed payment/refund left no trace at all.
        private readonly ILogger<FeePaymentService> _logger;

        public FeePaymentService(PgExec db, ILogger<FeePaymentService> logger)
        {
            _db = db;
            _logger = logger;
        }

        public async Task<(bool Success, string Message, string? ReceiptNo)> RecordRegistrationPaymentAsync(
            int enquiryId, decimal amount, string paymentMode, string? referenceNo,
            string? remarks, string? finYear, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || enquiryId <= 0)
                return (false, "Invalid request.", null);
            if (amount <= 0)
                return (false, "Payment amount must be greater than zero.", null);

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_enquiry_id",     NpgsqlDbType.Integer) { Value = enquiryId },
                new("p_amount",         NpgsqlDbType.Numeric) { Value = amount },
                new("p_payment_mode",   NpgsqlDbType.Text)    { Value = string.IsNullOrWhiteSpace(paymentMode) ? "Cash" : paymentMode },
                new("p_reference_no",   NpgsqlDbType.Text)    { Value = (object?)referenceNo ?? DBNull.Value },
                new("p_remarks",        NpgsqlDbType.Text)    { Value = (object?)remarks ?? DBNull.Value },
                new("p_payment_date",   NpgsqlDbType.Date)    { Value = DBNull.Value },
                new("p_fin_year",       NpgsqlDbType.Text)    { Value = (object?)finYear ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            try
            {
                (bool ok, string msg, string? rcp)? outcome = null;
                await _db.ExecuteCursorsAsync(SpRegistrationRecord, parameters, async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                    {
                        bool ok = DbRead.Bool(reader, cols, "success");
                        string msg = DbRead.NStr(reader, cols, "message") ?? (ok ? "Registration fee recorded." : "Error.");
                        string? rcp = DbRead.NStr(reader, cols, "receipt_no");
                        outcome = (ok, msg, rcp);
                    }
                });

                return outcome ?? (false, "No response.", null);
            }
            catch (PostgresException pex)
            {
                // WHY: a proc RAISE is usually a business rule (e.g. duplicate). Log at Warning with
                // SqlState so we can distinguish business rules from real DB faults, then surface the message.
                _logger.LogWarning(pex, "Registration fee payment rejected for enquiry {EnquiryId}, school {SchoolId}. SqlState {SqlState}", enquiryId, schoolId, pex.SqlState);
                return (false, pex.MessageText, null);
            }
            catch (Exception ex)
            {
                // WHY: unexpected failure in a money path must never be swallowed silently.
                _logger.LogError(ex, "Unexpected error recording registration fee for enquiry {EnquiryId}, school {SchoolId}.", enquiryId, schoolId);
                return (false, "Unable to record the registration fee.", null);
            }
        }

        public async Task<List<StudentDueItem>> GetStudentDuesAsync(
            int studentId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<StudentDueItem>();
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0)
                return list;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            await _db.ExecuteCursorsAsync(SpStudentDues, parameters, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                {
                    list.Add(new StudentDueItem
                    {
                        LedgerId         = DbRead.Int(reader, cols, "ledger_id"),
                        FeeHeadName      = DbRead.Str(reader, cols, "fee_head_name"),
                        Frequency        = DbRead.Str(reader, cols, "frequency"),
                        InstallmentLabel = DbRead.NStr(reader, cols, "installment_label"),
                        DueDate          = DbRead.Date(reader, cols, "due_date"),
                        AmountDue        = DbRead.Dec(reader, cols, "amount_due"),
                        AmountPaid       = DbRead.Dec(reader, cols, "amount_paid"),
                        Concession       = DbRead.Dec(reader, cols, "concession"),
                        Outstanding      = DbRead.Dec(reader, cols, "outstanding")
                    });
                }
            });

            return list;
        }

        public async Task<FeeCollectResult> CollectPaymentAsync(
            int studentId, List<FeeCollectItem> items, List<FeeExtraItem> extras, string paymentMode, string? referenceNo,
            string? remarks, string? finYear, int tenantId, int schoolId, int actionUserId,
            string? discountType = null, decimal discountValue = 0, string? discountReason = null,
            List<FeeTenderItem>? tenders = null, decimal advanceUsed = 0)
        {
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0)
                return new FeeCollectResult { Message = "Invalid request." };
            items  ??= new List<FeeCollectItem>();
            extras ??= new List<FeeExtraItem>();
            if (items.Count == 0 && extras.Count == 0)
                return new FeeCollectResult { Message = "Select at least one due or add an extra charge." };

            // Serialize the picked dues and ad-hoc extra charges as the JSON the proc expects.
            var itemsJson = JsonSerializer.Serialize(items.Select(i => new
            {
                ledgerId   = i.LedgerId,
                amount     = i.Amount,
                concession = i.Concession
            }));
            var extrasJson = JsonSerializer.Serialize(extras.Select(e => new
            {
                label  = e.Label,
                amount = e.Amount
            }));
            var tendersJson = (tenders != null && tenders.Count > 0)
                ? JsonSerializer.Serialize(tenders.Where(t => t.Amount > 0).Select(t => new
                {
                    mode      = string.IsNullOrWhiteSpace(t.Mode) ? "Cash" : t.Mode,
                    amount    = t.Amount,
                    reference = t.Reference
                }))
                : null;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_items",          NpgsqlDbType.Jsonb)   { Value = itemsJson },
                new("p_extras",         NpgsqlDbType.Jsonb)   { Value = extrasJson },
                new("p_payment_mode",   NpgsqlDbType.Text)    { Value = string.IsNullOrWhiteSpace(paymentMode) ? "Cash" : paymentMode },
                new("p_reference_no",   NpgsqlDbType.Text)    { Value = (object?)referenceNo ?? DBNull.Value },
                new("p_remarks",        NpgsqlDbType.Text)    { Value = (object?)remarks ?? DBNull.Value },
                new("p_payment_date",    NpgsqlDbType.Date)    { Value = DBNull.Value },
                new("p_fin_year",        NpgsqlDbType.Text)    { Value = (object?)finYear ?? DBNull.Value },
                new("p_discount_type",   NpgsqlDbType.Text)    { Value = (object?)discountType ?? DBNull.Value },
                new("p_discount_value",  NpgsqlDbType.Numeric) { Value = discountValue },
                new("p_discount_reason", NpgsqlDbType.Text)    { Value = (object?)discountReason ?? DBNull.Value },
                new("p_tenders",         NpgsqlDbType.Jsonb)   { Value = (object?)tendersJson ?? DBNull.Value },
                new("p_advance_used",    NpgsqlDbType.Numeric) { Value = advanceUsed },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            try
            {
                FeeCollectResult? result = null;
                await _db.ExecuteCursorsAsync(SpCollect, parameters, async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                    {
                        result = new FeeCollectResult
                        {
                            Success         = DbRead.Bool(reader, cols, "success"),
                            Message         = DbRead.NStr(reader, cols, "message") ?? "Payment recorded.",
                            ReceiptNo       = DbRead.NStr(reader, cols, "receipt_no"),
                            Amount          = DbRead.Dec(reader, cols, "amount"),
                            ConcessionTotal = DbRead.Dec(reader, cols, "concession_total"),
                            PaymentDate     = DbRead.Date(reader, cols, "payment_date")
                        };
                    }
                });

                return result ?? new FeeCollectResult { Message = "No response." };
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Fee collection rejected for student {StudentId}, school {SchoolId}. SqlState {SqlState}", studentId, schoolId, pex.SqlState);
                return new FeeCollectResult { Message = pex.MessageText };
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Unexpected error collecting fee for student {StudentId}, school {SchoolId}.", studentId, schoolId);
                return new FeeCollectResult { Message = "Unable to record the payment." };
            }
        }

        public async Task<List<FeePaymentHistoryItem>> GetPaymentHistoryAsync(
            int studentId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<FeePaymentHistoryItem>();
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0)
                return list;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            await _db.ExecuteCursorsAsync(SpHistory, parameters, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                {
                    list.Add(new FeePaymentHistoryItem
                    {
                        ReceiptNo       = DbRead.Str(reader, cols, "receipt_no"),
                        PaymentDate     = DbRead.Date(reader, cols, "payment_date"),
                        Amount          = DbRead.Dec(reader, cols, "amount"),
                        ConcessionTotal = DbRead.Dec(reader, cols, "concession_total"),
                        PaymentMode     = DbRead.Str(reader, cols, "payment_mode"),
                        ReferenceNo     = DbRead.NStr(reader, cols, "reference_no"),
                        IsCancelled     = DbRead.Bool(reader, cols, "is_cancelled"),
                        CancelReason    = DbRead.NStr(reader, cols, "cancel_reason")
                    });
                }
            });

            return list;
        }

        public async Task<(bool Success, string Message)> CancelReceiptAsync(
            string receiptNo, string reason, string? authorizedBy, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(receiptNo))
                return (false, "Invalid request.");
            if (string.IsNullOrWhiteSpace(reason))
                return (false, "A reason is required to cancel a receipt.");

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_receipt_no",     NpgsqlDbType.Text)    { Value = receiptNo.Trim() },
                new("p_reason",         NpgsqlDbType.Text)    { Value = reason.Trim() },
                new("p_authorized_by",  NpgsqlDbType.Text)    { Value = (object?)authorizedBy ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            try
            {
                (bool ok, string msg)? outcome = null;
                await _db.ExecuteCursorsAsync(SpCancel, parameters, async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                    {
                        bool ok = DbRead.Bool(reader, cols, "success");
                        string msg = DbRead.NStr(reader, cols, "message") ?? (ok ? "Receipt cancelled." : "Could not cancel.");
                        outcome = (ok, msg);
                    }
                });

                return outcome ?? (false, "No response.");
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Receipt cancel rejected for receipt {ReceiptNo}, school {SchoolId}. SqlState {SqlState}", receiptNo, schoolId, pex.SqlState);
                return (false, pex.MessageText);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Unexpected error cancelling receipt {ReceiptNo}, school {SchoolId}.", receiptNo, schoolId);
                return (false, "Unable to cancel the receipt.");
            }
        }

        public async Task<List<RefundableItem>> GetRefundablesAsync(
            int studentId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<RefundableItem>();
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0)
                return list;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            await _db.ExecuteCursorsAsync(SpRefundables, parameters, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                {
                    list.Add(new RefundableItem
                    {
                        LedgerId         = DbRead.Int(reader, cols, "ledger_id"),
                        FeeHeadName      = DbRead.Str(reader, cols, "fee_head_name"),
                        InstallmentLabel = DbRead.NStr(reader, cols, "installment_label"),
                        AmountPaid       = DbRead.Dec(reader, cols, "amount_paid"),
                        Refunded         = DbRead.Dec(reader, cols, "refund_amount"),
                        Refundable       = DbRead.Dec(reader, cols, "refundable"),
                        IsRefundable     = DbRead.Bool(reader, cols, "is_refundable")
                    });
                }
            });

            return list;
        }

        public async Task<(bool Success, string Message, string? RefundNo)> RecordRefundAsync(
            int studentId, int ledgerId, decimal amount, string mode, string reason,
            string? authorizedBy, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0 || ledgerId <= 0)
                return (false, "Invalid request.", null);
            if (amount <= 0)
                return (false, "Refund amount must be greater than zero.", null);
            if (string.IsNullOrWhiteSpace(reason))
                return (false, "A reason is required to refund.", null);

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_ledger_id",      NpgsqlDbType.Integer) { Value = ledgerId },
                new("p_amount",         NpgsqlDbType.Numeric) { Value = amount },
                new("p_mode",           NpgsqlDbType.Text)    { Value = string.IsNullOrWhiteSpace(mode) ? "Cash" : mode },
                new("p_reason",         NpgsqlDbType.Text)    { Value = reason.Trim() },
                new("p_authorized_by",  NpgsqlDbType.Text)    { Value = (object?)authorizedBy ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            try
            {
                (bool ok, string msg, string? no)? outcome = null;
                await _db.ExecuteCursorsAsync(SpRefund, parameters, async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                    {
                        bool ok = DbRead.Bool(reader, cols, "success");
                        string msg = DbRead.NStr(reader, cols, "message") ?? (ok ? "Refund recorded." : "Could not refund.");
                        string? no = DbRead.NStr(reader, cols, "refund_no");
                        outcome = (ok, msg, no);
                    }
                });

                return outcome ?? (false, "No response.", null);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Refund rejected for student {StudentId}, ledger {LedgerId}, school {SchoolId}. SqlState {SqlState}", studentId, ledgerId, schoolId, pex.SqlState);
                return (false, pex.MessageText, null);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Unexpected error recording refund for student {StudentId}, ledger {LedgerId}, school {SchoolId}.", studentId, ledgerId, schoolId);
                return (false, "Unable to record the refund.", null);
            }
        }

        public async Task<DayCollection> GetDayCollectionAsync(
            DateOnly? date, int tenantId, int schoolId, int actionUserId)
        {
            var day = new DayCollection { Date = date ?? DateOnly.FromDateTime(DateTime.Today) };
            if (tenantId <= 1 || schoolId <= 0)
                return day;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_date",           NpgsqlDbType.Date)    { Value = (object?)date ?? DBNull.Value },
                new("p_summary", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "summary_cursor" },
                new("p_modes",   NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "modes_cursor" }
            };

            await _db.ExecuteCursorsAsync(SpDayCollection, parameters,
                // cursor 0: summary (single row)
                async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                    {
                        day.Date           = DbRead.Date(reader, cols, "close_date") ?? day.Date;
                        day.TotalCollected = DbRead.Dec(reader, cols, "total_collected");
                        day.ReceiptCount   = DbRead.Int(reader, cols, "receipt_count");
                        day.CancelledCount = DbRead.Int(reader, cols, "cancelled_count");
                        day.CashCollected  = DbRead.Dec(reader, cols, "cash_collected");
                        day.TotalRefunded  = DbRead.Dec(reader, cols, "total_refunded");
                        day.CashRefunded   = DbRead.Dec(reader, cols, "cash_refunded");
                        day.ExpectedCash   = day.CashCollected - day.CashRefunded;
                        day.IsClosed       = DbRead.Bool(reader, cols, "is_closed");
                        day.CountedCash    = DbRead.Dec(reader, cols, "counted_cash");
                        day.Difference     = DbRead.Dec(reader, cols, "difference");
                        day.CloseRemarks   = DbRead.NStr(reader, cols, "close_remarks");
                    }
                },
                // cursor 1: per-mode breakdown (many rows)
                async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                    {
                        day.Modes.Add(new DayModeRow
                        {
                            Mode   = DbRead.Str(reader, cols, "payment_mode"),
                            Amount = DbRead.Dec(reader, cols, "amount"),
                            Count  = DbRead.Int(reader, cols, "cnt")
                        });
                    }
                });

            return day;
        }

        public async Task<(bool Success, string Message, decimal ExpectedCash, decimal Difference)> CloseDayAsync(
            DateOnly? date, decimal countedCash, string? remarks, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return (false, "Invalid request.", 0, 0);

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_date",           NpgsqlDbType.Date)    { Value = (object?)date ?? DBNull.Value },
                new("p_counted_cash",   NpgsqlDbType.Numeric) { Value = countedCash },
                new("p_remarks",        NpgsqlDbType.Text)    { Value = (object?)remarks ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            try
            {
                (bool ok, string msg, decimal exp, decimal diff)? outcome = null;
                await _db.ExecuteCursorsAsync(SpDayClose, parameters, async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                    {
                        bool ok = DbRead.Bool(reader, cols, "success");
                        string msg = DbRead.NStr(reader, cols, "message") ?? (ok ? "Day closed." : "Could not close.");
                        decimal exp = DbRead.Dec(reader, cols, "expected_cash");
                        decimal diff = DbRead.Dec(reader, cols, "difference");
                        outcome = (ok, msg, exp, diff);
                    }
                });

                return outcome ?? (false, "No response.", 0, 0);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Day close rejected for school {SchoolId}, date {Date}. SqlState {SqlState}", schoolId, date, pex.SqlState);
                return (false, pex.MessageText, 0, 0);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Unexpected error closing day for school {SchoolId}, date {Date}.", schoolId, date);
                return (false, "Unable to close the day.", 0, 0);
            }
        }

        public async Task<CollectionRegister> GetCollectionRegisterAsync(
            DateOnly? from, DateOnly? to, int tenantId, int schoolId, int actionUserId)
        {
            var reg = new CollectionRegister
            {
                From = from ?? DateOnly.FromDateTime(DateTime.Today),
                To   = to   ?? DateOnly.FromDateTime(DateTime.Today)
            };
            if (tenantId <= 1 || schoolId <= 0)
                return reg;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_from",           NpgsqlDbType.Date)    { Value = (object?)from ?? DBNull.Value },
                new("p_to",             NpgsqlDbType.Date)    { Value = (object?)to   ?? DBNull.Value },
                new("p_receipts", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "receipts_cursor" },
                new("p_modes",    NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "modes_cursor" },
                new("p_heads",    NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "heads_cursor" }
            };

            await _db.ExecuteCursorsAsync(SpCollectionRegister, parameters,
                async reader =>   // cursor 0: receipts
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                    {
                        reg.Receipts.Add(new RegisterReceipt
                        {
                            ReceiptNo   = DbRead.Str(reader, cols, "receipt_no"),
                            Date        = DbRead.Date(reader, cols, "payment_date"),
                            Amount      = DbRead.Dec(reader, cols, "amount"),
                            Mode        = DbRead.Str(reader, cols, "payment_mode"),
                            StudentName = DbRead.Str(reader, cols, "student_name"),
                            AdmissionNo = DbRead.Str(reader, cols, "admission_no"),
                            ClassName   = DbRead.NStr(reader, cols, "class_name"),
                            Section     = DbRead.NStr(reader, cols, "section")
                        });
                    }
                },
                async reader =>   // cursor 1: per-mode totals
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                    {
                        reg.Modes.Add(new DayModeRow
                        {
                            Mode   = DbRead.Str(reader, cols, "payment_mode"),
                            Amount = DbRead.Dec(reader, cols, "amount"),
                            Count  = DbRead.Int(reader, cols, "cnt")
                        });
                    }
                },
                async reader =>   // cursor 2: per-head totals
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                    {
                        reg.Heads.Add(new HeadCollectRow
                        {
                            Head   = DbRead.Str(reader, cols, "fee_head_name"),
                            Count  = DbRead.Int(reader, cols, "cnt"),
                            Amount = DbRead.Dec(reader, cols, "amount")
                        });
                    }
                });

            return reg;
        }

        public async Task<(List<ConcessionRow> Concessions, List<CancellationRow> Cancellations)> GetConcessionCancelRegisterAsync(
            DateOnly? from, DateOnly? to, int tenantId, int schoolId, int actionUserId)
        {
            var concessions = new List<ConcessionRow>();
            var cancels = new List<CancellationRow>();
            if (tenantId <= 1 || schoolId <= 0)
                return (concessions, cancels);

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_from",           NpgsqlDbType.Date)    { Value = (object?)from ?? DBNull.Value },
                new("p_to",             NpgsqlDbType.Date)    { Value = (object?)to   ?? DBNull.Value },
                new("p_concessions", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "concessions_cursor" },
                new("p_cancels",     NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cancels_cursor" }
            };

            await _db.ExecuteCursorsAsync(SpConcessionCancel, parameters,
                async reader =>   // cursor 0: concessions
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                    {
                        concessions.Add(new ConcessionRow
                        {
                            ReceiptNo     = DbRead.Str(reader, cols, "receipt_no"),
                            Date          = DbRead.Date(reader, cols, "payment_date"),
                            Concession    = DbRead.Dec(reader, cols, "concession_total"),
                            DiscountType  = DbRead.NStr(reader, cols, "discount_type"),
                            DiscountValue = DbRead.Dec(reader, cols, "discount_value"),
                            Reason        = DbRead.NStr(reader, cols, "discount_reason"),
                            Student       = DbRead.Str(reader, cols, "student_name"),
                            AdmNo         = DbRead.Str(reader, cols, "admission_no")
                        });
                    }
                },
                async reader =>   // cursor 1: cancellations
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                    {
                        cancels.Add(new CancellationRow
                        {
                            ReceiptNo    = DbRead.Str(reader, cols, "receipt_no"),
                            Date         = DbRead.Date(reader, cols, "payment_date"),
                            Amount       = DbRead.Dec(reader, cols, "amount"),
                            Reason       = DbRead.NStr(reader, cols, "cancel_reason"),
                            AuthorizedBy = DbRead.NStr(reader, cols, "cancel_authorized_by"),
                            CancelledAt  = DbRead.DateTimeN(reader, cols, "cancelled_at"),
                            Student      = DbRead.Str(reader, cols, "student_name"),
                            AdmNo        = DbRead.Str(reader, cols, "admission_no")
                        });
                    }
                });

            return (concessions, cancels);
        }

        public async Task<decimal> GetStudentAdvanceAsync(
            int studentId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0)
                return 0;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            decimal balance = 0;
            await _db.ExecuteCursorsAsync(SpAdvanceGet, parameters, async reader =>
            {
                var cols = reader.Columns();
                if (await reader.ReadAsync())
                    balance = DbRead.Dec(reader, cols, "balance");
            });

            return balance;
        }

        public async Task<List<DefaulterRow>> GetDefaultersAsync(
            string? className, string? section, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<DefaulterRow>();
            if (tenantId <= 1 || schoolId <= 0)
                return list;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_class",          NpgsqlDbType.Text)    { Value = (object?)className ?? DBNull.Value },
                new("p_section",        NpgsqlDbType.Text)    { Value = (object?)section   ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            await _db.ExecuteCursorsAsync(SpDefaulters, parameters, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                {
                    list.Add(new DefaulterRow
                    {
                        StudentId        = DbRead.Int(reader, cols, "student_id"),
                        StudentName      = DbRead.Str(reader, cols, "student_name"),
                        AdmissionNo      = DbRead.Str(reader, cols, "admission_no"),
                        ClassName        = DbRead.NStr(reader, cols, "class_name"),
                        Section          = DbRead.NStr(reader, cols, "section"),
                        RollNo           = DbRead.NStr(reader, cols, "roll_no"),
                        TotalOutstanding = DbRead.Dec(reader, cols, "total_outstanding"),
                        NotDue           = DbRead.Dec(reader, cols, "not_due"),
                        D0_30            = DbRead.Dec(reader, cols, "d0_30"),
                        D31_60           = DbRead.Dec(reader, cols, "d31_60"),
                        D60Plus          = DbRead.Dec(reader, cols, "d60_plus")
                    });
                }
            });

            return list;
        }

        public async Task<FeeReceipt?> GetReceiptAsync(
            string receiptNo, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(receiptNo))
                return null;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_receipt_no",     NpgsqlDbType.Text)    { Value = receiptNo.Trim() },
                new("p_header", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "header_cursor" },
                new("p_lines",  NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "lines_cursor" }
            };

            try
            {
                FeeReceipt? receipt = null;
                await _db.ExecuteCursorsAsync(SpReceipt, parameters,
                    async reader =>   // cursor 0: header (single row)
                    {
                        var cols = reader.Columns();
                        if (await reader.ReadAsync())
                        {
                            receipt = new FeeReceipt
                            {
                                ReceiptNo       = DbRead.Str(reader, cols, "receipt_no"),
                                PaymentDate     = DbRead.Date(reader, cols, "payment_date"),
                                Amount          = DbRead.Dec(reader, cols, "amount"),
                                ConcessionTotal = DbRead.Dec(reader, cols, "concession_total"),
                                PaymentMode     = DbRead.Str(reader, cols, "payment_mode"),
                                ReferenceNo     = DbRead.NStr(reader, cols, "reference_no"),
                                Remarks         = DbRead.NStr(reader, cols, "remarks"),
                                PaymentType     = DbRead.NStr(reader, cols, "payment_type") ?? "Fee",
                                DiscountType    = DbRead.NStr(reader, cols, "discount_type"),
                                DiscountValue   = DbRead.Dec(reader, cols, "discount_value"),
                                DiscountReason  = DbRead.NStr(reader, cols, "discount_reason"),
                                AdvanceUsed     = DbRead.Dec(reader, cols, "advance_used"),
                                AdvanceCredit   = DbRead.Dec(reader, cols, "advance_credit"),
                                StudentName     = DbRead.Str(reader, cols, "student_name"),
                                AdmissionNo     = DbRead.Str(reader, cols, "admission_no"),
                                ClassName       = DbRead.Str(reader, cols, "class_name"),
                                Section         = DbRead.NStr(reader, cols, "section"),
                                RollNo          = DbRead.NStr(reader, cols, "roll_no")
                            };
                        }
                    },
                    async reader =>   // cursor 1: lines (many rows)
                    {
                        if (receipt == null) return;
                        var cols = reader.Columns();
                        while (await reader.ReadAsync())
                        {
                            receipt.Lines.Add(new FeeReceiptLine
                            {
                                FeeHeadName      = DbRead.Str(reader, cols, "fee_head_name"),
                                InstallmentLabel = DbRead.NStr(reader, cols, "installment_label"),
                                Amount           = DbRead.Dec(reader, cols, "amount"),
                                Concession       = DbRead.Dec(reader, cols, "concession"),
                                LineType         = DbRead.NStr(reader, cols, "line_type") ?? "Due"
                            });
                        }
                    });

                return receipt;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Failed to load receipt {ReceiptNo} for school {SchoolId}.", receiptNo, schoolId);
                return null;
            }
        }
    }
}
