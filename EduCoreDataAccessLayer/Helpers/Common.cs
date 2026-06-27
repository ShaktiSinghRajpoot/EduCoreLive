using System.IO;

namespace EduCoreDataAccessLayer.Helpers
{
    public static class Common
    {
        public const string ResultSuccess = "1";
        public const string ResultError = "0";

        public const string SK_TenantId = "_tenantid";
        public const string SK_SchoolId = "_schoolid";
        public const string SK_EmailId = "_emailid";

        public const string SK_UserId = "_userid";
        public const string SK_RoleId = "_roleid";
        // Session key: the role a multi-role user has chosen to "focus" on (0/absent = combined view of all roles).
        public const string SK_ActiveRoleId = "_activeroleid";
        public const string SK_UserName = "_username";
        public const string SK_Desig = "_desig";
        public const string SK_ThemeMode = "_thememode";
        public const string SK_ThemeColor = "_themecolor";
        public const string EncryptionKey = "UCS@!$MEHRAQRGH";
        //public const string SK_ModuleId = "_moduleid";

        public const string ResultMsgMandatory = "All (*) marked fields are mandatory";
        public const string ResultMsgSomethingWentWrong = "Something went wrong please try again";
        public const string DcFileUploadInfoMsg = "(pdf, png, jpg, jpeg, gif, tif, doc, docx)";
        public const string DcFileUploadValidationMsg = "Only Pdf, Png, Jpg, Jpeg, Gif, Tif, Doc, Docx files are allowed.";
        public const string DcFileUploadFileSizeValidationMsg = "File size is greater than 2MB. Please upload file below 2MB.";
    }

    public static class Usp
    {
        public const string LoginInfo = "USP19_LoginInfo";
        public const string BasicInfo = "USP19_BasicInfo";
        public const string DCMaster = "USP19_DCMaster";
        public const string DCTransaction = "USP19_DCTransaction";
        public const string DCMIS = "USP19_DCMIS_Kalpana";
        public const string DCUtility = "USP19_DCUtility";
        public const string CMNProc = "USP20_Common";
    }

    public static class ModuleIconColor
    {
        public const string BIR = "icon-stack bg-primary bg-primary-gradient rounded mb-1";
        public const string DC = "icon-stack bg-secondary bg-secondary-gradient rounded mb-1";
        public const string UserManagement = "icon-stack bg-success bg-success-gradient rounded mb-1";
        public const string ProspectManagement = "icon-stack bg-warning bg-warning-gradient rounded mb-1";
        public const string Accounts = "icon-stack bg-danger bg-danger-gradient rounded mb-1";
        public const string HR = "icon-stack bg-info bg-info-gradient rounded mb-1";
        public const string Common = "icon-stack bg-fusion-900 bg-fusion-gradient rounded mb-1";
        public const string InvoiceManagement = "icon-stack bg-brand-gradient rounded mb-1";
    }

    public static class MyServer
    {
        public static string MapPath(string path)
        {
            return Path.Combine(Directory.GetCurrentDirectory(), "TempFile\\Data.json");
        }
    }

    public static class AppRoles
    {
        public const string SuperAdmin = "SUPER_ADMIN";
        public const string SchoolAdmin = "SCHOOL_ADMIN";
        public const string Teacher = "TEACHER";
        public const string Accountant = "ACCOUNTANT";
        public const string Receptionist = "RECEPTIONIST";
    }
}