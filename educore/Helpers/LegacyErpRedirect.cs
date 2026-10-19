namespace educore.Helpers
{
    /// <summary>
    /// Old links keep working while the pages move out of the one big "ERP" area
    /// into one area per module (Fees, Inventory, ...).
    ///
    /// /ERP/{Controller}/{rest}  ->  /{area}/{Controller}/{rest}  (query string kept)
    ///
    /// A bookmark, a link in a WhatsApp message or an open tab is sent on with a
    /// 301. A POST gets a 308 instead, so the browser repeats it with its body (a
    /// 301 would turn it into a GET and lose the form). Each phase of the move adds
    /// its controllers to <see cref="MovedControllers"/>; a controller that is not
    /// listed is still in ERP and is left alone.
    /// </summary>
    public static class LegacyErpRedirect
    {
        // controller name -> the area it lives in now
        public static readonly Dictionary<string, string> MovedControllers = new(StringComparer.OrdinalIgnoreCase)
        {
            { "Inventory", "Inventory" },
            { "StoreRegister", "Inventory" },
            { "Transport", "Transport" },
            { "MyBus", "Transport" },
            { "Fee", "Fees" },
            { "FeeDashboard", "Fees" },
            { "FeeDues", "Fees" },
            { "FeeDueReminders", "Fees" },
            { "DayClose", "Fees" },
        };

        // Pages that got a short address of their own: "Controller/Action" -> new path.
        // (Their old long form would not open: an action with its own route answers only there.)
        public static readonly Dictionary<string, string> MovedPages = new(StringComparer.OrdinalIgnoreCase)
        {
            { "Inventory", "/inventory" },
            { "Inventory/Index", "/inventory" },
            { "Inventory/StoreDashboard", "/inventory" },
            { "Inventory/InventoryItem", "/inventory/store" },
            { "Inventory/StoreLocations", "/inventory/locations" },
            { "Inventory/SupplierMaster", "/inventory/suppliers" },
            { "Inventory/PurchaseEntry", "/inventory/purchase" },
            { "Inventory/StudentSale", "/inventory/give-items" },
            { "Inventory/ClassSale", "/inventory/class-items" },
            { "Inventory/OrderList", "/inventory/order-list" },
            { "StoreRegister", "/inventory/register" },
            { "StoreRegister/Index", "/inventory/register" },
            { "Transport", "/transport/live" },
            { "Transport/Index", "/transport/live" },
            { "Transport/Routes", "/transport/routes" },
            { "Transport/Vehicles", "/transport/vehicles" },
            { "Transport/Assign", "/transport/assign" },
            { "Transport/LiveTracking", "/transport/live" },
            { "Transport/TripHistory", "/transport/trips" },
            { "MyBus", "/my-bus" },
            { "MyBus/Index", "/my-bus" },
            { "FeeDashboard", "/fees" },
            { "FeeDashboard/Index", "/fees" },
            { "Fee/ManageFee", "/fees/collect" },
            { "Fee/Reports", "/fees/reports" },
            { "Fee/YearEnd", "/fees/year-end" },
            { "FeeDues", "/fees/dues" },
            { "FeeDues/Index", "/fees/dues" },
            { "FeeDueReminders", "/fees/dues" },
            { "FeeDueReminders/Index", "/fees/dues" },
            { "DayClose", "/fees/day-close" },
            { "DayClose/Index", "/fees/day-close" },
            // receipts left Fee for the always-on Receipt controller
            { "Fee/GetReceipt", "/school/receipt/getreceipt" },
            { "Fee/GetSchoolHeader", "/school/receipt/getschoolheader" },
            { "Fee/CancelReceipt", "/school/receipt/cancelreceipt" },
            { "Fee/SaveReceiptFormat", "/school/receipt/savereceiptformat" },
            // fee heads and structure left SchoolSettings (which is still in ERP)
            { "SchoolSettings/FeeHead", "/fees/heads" },
            { "SchoolSettings/FeeStructure", "/fees/structure" },
            { "SchoolSettings/SaveFeeHead", "/fees/feesetup/savefeehead" },
            { "SchoolSettings/GetFeeHeadById", "/fees/feesetup/getfeeheadbyid" },
            { "SchoolSettings/DeleteFeeHead", "/fees/feesetup/deletefeehead" },
            { "SchoolSettings/ToggleFeeHeadStatus", "/fees/feesetup/togglefeeheadstatus" },
            { "SchoolSettings/CopyFeeStructure", "/fees/feesetup/copyfeestructure" },
            { "SchoolSettings/GetFeeStructureByClass", "/fees/feesetup/getfeestructurebyclass" },
            { "SchoolSettings/SaveFeeStructure", "/fees/feesetup/savefeestructure" },
            { "SchoolSettings/DeleteFeeStructure", "/fees/feesetup/deletefeestructure" },
        };

        public static IApplicationBuilder UseLegacyErpRedirect(this IApplicationBuilder app)
        {
            return app.Use(async (context, next) =>
            {
                var path = context.Request.Path.Value ?? "";
                if (path.StartsWith("/ERP/", StringComparison.OrdinalIgnoreCase))
                {
                    // "/ERP/Fee/ManageFee" -> controller "Fee", rest "/ManageFee"
                    var afterArea = path.Substring(5);
                    int slash = afterArea.IndexOf('/');
                    var controller = slash < 0 ? afterArea : afterArea.Substring(0, slash);
                    var rest = slash < 0 ? "" : afterArea.Substring(slash);

                    string? target = null;
                    if (MovedPages.TryGetValue(afterArea.TrimEnd('/'), out var page))
                        target = page;
                    else if (MovedControllers.TryGetValue(controller, out var area))
                        target = "/" + area.ToLowerInvariant() + "/" + controller.ToLowerInvariant() + rest;

                    if (target != null)
                    {
                        target += context.Request.QueryString.Value;
                        bool isGet = HttpMethods.IsGet(context.Request.Method) || HttpMethods.IsHead(context.Request.Method);
                        context.Response.StatusCode = isGet ? StatusCodes.Status301MovedPermanently
                                                            : StatusCodes.Status308PermanentRedirect;
                        context.Response.Headers.Location = target;
                        return;
                    }
                }
                await next();
            });
        }
    }
}
