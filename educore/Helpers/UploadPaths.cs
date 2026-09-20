namespace educore.Helpers
{
    /// <summary>
    /// Where uploaded files are written, and the URL they are served from.
    ///
    /// Uploads used to go straight into <c>wwwroot/uploads</c>. That folder lives
    /// inside the published app, so on a container host it is part of the image
    /// and is replaced on every deploy: the database kept pointing at
    /// <c>/uploads/students/…</c> while the file behind it had been thrown away.
    /// Student photos and school logos disappeared each time the app shipped.
    ///
    /// The root is therefore configurable, exactly like the Data Protection key
    /// ring next to it in Program.cs. In production it is set to a MOUNTED VOLUME
    /// so the files outlive the container; locally it stays under wwwroot so
    /// nothing changes for development.
    /// </summary>
    public static class UploadPaths
    {
        /// The URL prefix these files are served from, whatever disk they live on.
        public const string RequestPath = "/uploads";

        /// <summary>
        /// The folder uploads are written to. A relative setting resolves against
        /// the content root; an absolute one (a mounted volume) is used as given.
        /// </summary>
        public static string Root(IConfiguration config, IWebHostEnvironment env)
        {
            var configured = config["Uploads:Root"];

            // Nothing configured: the old location, so development is unchanged.
            if (string.IsNullOrWhiteSpace(configured))
                return Path.Combine(env.WebRootPath, "uploads");

            return Path.IsPathRooted(configured)
                ? configured
                : Path.Combine(env.ContentRootPath, configured);
        }

        /// <summary>
        /// The folder for one school's files of a given kind, created if needed.
        /// Every caller used to build this path itself, which is how the three
        /// upload endpoints drifted into slightly different code for the same job.
        /// </summary>
        public static string FolderFor(
            IConfiguration config, IWebHostEnvironment env,
            string kind, int tenantId, int schoolId)
        {
            var folder = Path.Combine(Root(config, env), kind,
                                      tenantId.ToString(), schoolId.ToString());
            Directory.CreateDirectory(folder);
            return folder;
        }

        /// <summary>
        /// The URL for a stored file. Unchanged in shape from before this moved,
        /// so every <c>photo_url</c> and <c>logo_url</c> already in the database
        /// still resolves.
        /// </summary>
        public static string UrlFor(string kind, int tenantId, int schoolId, string fileName)
            => $"{RequestPath}/{kind}/{tenantId}/{schoolId}/{fileName}";
    }
}
