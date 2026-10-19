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
