using System.Globalization;

namespace EduCoreDataAccessLayer.Helpers
{
    /// <summary>
    /// Rupee amounts for server-rendered pages, grouped the Indian way
    /// (5,67,200 not 567,200). ToString("N0") on its own uses the server's
    /// culture, which on Railway is not India.
    /// </summary>
    public static class Money
    {
        private static readonly CultureInfo India = CultureInfo.GetCultureInfo("en-IN");

        public static string Inr(decimal value) => value.ToString("N0", India);
    }
}
