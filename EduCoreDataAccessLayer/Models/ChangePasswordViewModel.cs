using System.ComponentModel.DataAnnotations;

namespace educore.Models
{
    public class ChangePasswordViewModel
    {
        // Not [Required] at the attribute level: on the forced first-login reset the
        // user just signed in with the temp password, so we don't ask for it again.
        // Required + verified in the controller only for a normal (self-service) change.
        [DataType(DataType.Password)]
        public string CurrentPassword { get; set; } = string.Empty;

        [Required(ErrorMessage = "New password is required.")]
        [StringLength(100, MinimumLength = 8, ErrorMessage = "Password must be at least 8 characters.")]
        [DataType(DataType.Password)]
        public string NewPassword { get; set; } = string.Empty;

        [Required(ErrorMessage = "Please confirm the new password.")]
        [DataType(DataType.Password)]
        [Compare(nameof(NewPassword), ErrorMessage = "Passwords do not match.")]
        public string ConfirmPassword { get; set; } = string.Empty;

        /// <summary>True when shown because of the forced first-login reset (tweaks copy).</summary>
        public bool IsForced { get; set; }
    }
}
