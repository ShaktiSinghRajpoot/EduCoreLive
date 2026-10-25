namespace educore.Models
{
    /// <summary>
    /// One question on a public website page (Views/Site). The _Faq partial shows the
    /// list and writes the same questions as FAQPage structured data for search engines.
    /// </summary>
    public class SiteFaq
    {
        public string Q { get; }
        public string A { get; }

        public SiteFaq(string q, string a)
        {
            Q = q;
            A = a;
        }
    }
}
