using System.ComponentModel.DataAnnotations;

namespace educore.Models
{
    public class ForgotPasswordViewModel
    {
        [Required(ErrorMessage = "Enter your email or mobile number.")]
        [Display(Name = "Email or mobile number")]
        public string Identifier { get; set; } = string.Empty;
    }
}
