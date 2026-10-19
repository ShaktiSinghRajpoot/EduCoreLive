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

                    if (MovedControllers.TryGetValue(controller, out var area))
                    {
                        var target = "/" + area.ToLowerInvariant() + "/" + controller.ToLowerInvariant() + rest
                                   + context.Request.QueryString.Value;
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
