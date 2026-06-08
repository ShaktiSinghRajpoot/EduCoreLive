using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    public class ExamController : Controller
    {
        public IActionResult CreateExam()
        {
            return View();
        }

        public IActionResult MarkEntry(int examId = 0, string className = " ", string section = "", string subject = "")
        {
            ViewBag.ExamId    = examId;
            ViewBag.ClassName = className;
            ViewBag.Section   = section;
            ViewBag.Subject   = subject;
            return View();
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public IActionResult SaveMarks(IFormCollection form)
        {
            // Replace with real service call once SP is ready
            bool finalize = form["action"] == "finalize";
            TempData["SuccessMessage"] = finalize ? "Marks finalized and locked successfully." : "Marks saved as draft successfully.";

            return RedirectToAction("MarkEntry", new
            {
                examId    = form["ExamId"],
                className = form["ClassName"],
                section   = form["Section"],
                subject   = form["Subject"]
            });
        }
    }
}
