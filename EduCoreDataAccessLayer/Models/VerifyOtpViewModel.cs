using System.ComponentModel.DataAnnotations;

namespace educore.Models
{
    public class VerifyOtpViewModel
    {
        [Required(ErrorMessage = "Enter the 6-digit code.")]
        [RegularExpression(@"^\d{6}$", ErrorMessage = "The code is 6 digits.")]
        [Display(Name = "Verification code")]
        public string Otp { get; set; } = string.Empty;

        [Required(ErrorMessage = "New password is required.")]
        [StringLength(100, MinimumLength = 8, ErrorMessage = "Password must be at least 8 characters.")]
        [DataType(DataType.Password)]
        public string NewPassword { get; set; } = string.Empty;

        [Required(ErrorMessage = "Please confirm the new password.")]
        [DataType(DataType.Password)]
        [Compare(nameof(NewPassword), ErrorMessage = "Passwords do not match.")]
        public string ConfirmPassword { get; set; } = string.Empty;

        /// <summary>Masked destination (e.g. "j***@x.com / ****1234") shown for reassurance.</summary>
        public string? SentTo { get; set; }
    }
}
