using Microsoft.AspNetCore.Mvc.Rendering;
using System.Data;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace EduCoreDataAccessLayer.Helpers
{
    public static class Utility
    {
        public static string Encrypt(string clearText)
        {
            try
            {
                char[] padding = { '=' };
                byte[] clearBytes = Encoding.Unicode.GetBytes(clearText);
                using (Aes encryptor = Aes.Create())
                {
                    Rfc2898DeriveBytes pdb = new Rfc2898DeriveBytes(Common.EncryptionKey, new byte[] { 0x49, 0x76, 0x61, 0x6e, 0x20, 0x4d, 0x65, 0x64, 0x76, 0x65, 0x64, 0x65, 0x76 });
                    encryptor.Key = pdb.GetBytes(32);
                    encryptor.IV = pdb.GetBytes(16);
                    MemoryStream ms = new MemoryStream();
                    using (CryptoStream cs = new CryptoStream(ms, encryptor.CreateEncryptor(), CryptoStreamMode.Write))
                    {
                        cs.Write(clearBytes, 0, clearBytes.Length);
                        cs.Close();
                    }
                    clearText = Convert.ToBase64String(ms.ToArray()).TrimEnd(padding).Replace('+', '-').Replace('/', '_');
                }
                return clearText;
            }
            catch
            {
            }
            return "";
        }
        public static string Decrypt(string cipherText)
        {
            string incoming = cipherText.Replace('_', '/').Replace('-', '+');
            switch (cipherText.Length % 4)
            {
                case 2: incoming += "=="; break;
                case 3: incoming += "="; break;
            }
            try
            {
                byte[] cipherBytes = Convert.FromBase64String(incoming);
                using (Aes encryptor = Aes.Create())
                {
                    Rfc2898DeriveBytes pdb = new Rfc2898DeriveBytes(Common.EncryptionKey, new byte[] { 0x49, 0x76, 0x61, 0x6e, 0x20, 0x4d, 0x65, 0x64, 0x76, 0x65, 0x64, 0x65, 0x76 });
                    encryptor.Key = pdb.GetBytes(32);
                    encryptor.IV = pdb.GetBytes(16);
                    MemoryStream ms = new MemoryStream();
                    using (CryptoStream cs = new CryptoStream(ms, encryptor.CreateDecryptor(), CryptoStreamMode.Write))
                    {
                        cs.Write(cipherBytes, 0, cipherBytes.Length);
                        cs.Close();
                    }
                    cipherText = Encoding.Unicode.GetString(ms.ToArray());
                }
                return cipherText;
            }
            catch
            {
            }
            return "";
        }
        public static List<SelectListItem> GetMonthList()
        {
            return new List<SelectListItem>()
            {
                new SelectListItem() { Value = "Jan", Text = "Jan" },
                new SelectListItem() { Value = "Feb", Text = "Feb" },
                new SelectListItem() { Value = "Mar", Text = "Mar" },
                new SelectListItem() { Value = "Apr", Text = "Apr" },
                new SelectListItem() { Value = "May", Text = "May" },
                new SelectListItem() { Value = "Jun", Text = "Jun" },
                new SelectListItem() { Value = "Jul", Text = "Jul" },
                new SelectListItem() { Value = "Aug", Text = "Aug" },
                new SelectListItem() { Value = "Sep", Text = "Sep" },
                new SelectListItem() { Value = "Oct", Text = "Oct" },
                new SelectListItem() { Value = "Nov", Text = "Nov" },
                new SelectListItem() { Value = "Dec", Text = "Dec" }
            };
        }
        public static List<SelectListItem> GetDayList(int month, int year)
        {
            return Enumerable.Range(1, DateTime.DaysInMonth(year, month)).Select(day => new SelectListItem { Text = day.ToString(), Value = day.ToString() }).ToList(); ;
        }
        public static List<SelectListItem> GetYearList()
        {
            var data = new List<SelectListItem>();
            for (int i = DateTime.Now.Year; i >= 1800; i--)
            {
                data.Add(new SelectListItem() { Value = i.ToString(), Text = i.ToString() });
            }
            return data;
        }
        public static DataTable GetCompIdInDataTable(string commaCompID)
        {
            DataTable tbl = new DataTable("tbl");
            if (!tbl.Columns.Contains("CompanyID"))
            {
                tbl.Columns.Add("CompanyID", typeof(long));
            }
            if (!string.IsNullOrEmpty(commaCompID))
            {
                string[] strcommaCompID = commaCompID.Replace("'", "`").Split(',');
                int num2 = checked(strcommaCompID.Length);
                int index = 0;
                while (index < num2)
                {
                    DataRow dr = tbl.NewRow();
                    dr["CompanyID"] = Convert.ToInt64(strcommaCompID[index]);
                    tbl.Rows.Add(dr);
                    checked { ++index; }
                }
            }
            return tbl;
        }
        public static DataTable GetCountryIdInDataTable(string commaCountryID)
        {
            DataTable tbl = new DataTable("tbl");
            if (!tbl.Columns.Contains("CountryID"))
            {
                tbl.Columns.Add("CountryID", typeof(long));
            }
            if (!string.IsNullOrEmpty(commaCountryID))
            {
                string[] strcommaCompID = commaCountryID.Replace("'", "`").Split(',');
                int num2 = checked(strcommaCompID.Length);
                int index = 0;
                while (index < num2)
                {
                    DataRow dr = tbl.NewRow();
                    dr["CountryID"] = Convert.ToInt64(strcommaCompID[index]);
                    tbl.Rows.Add(dr);
                    checked { ++index; }
                }
            }
            return tbl;
        }
        public static string ReplaceAllSpecialCharacterswithSpace(string str)
        {
            return Regex.Replace(str, @"[^0-9a-zA-Z\._]", string.Empty);
        }
    }
}