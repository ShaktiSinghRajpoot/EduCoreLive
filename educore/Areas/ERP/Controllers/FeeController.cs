using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    public class FeeController : Controller
    {
        public IActionResult ManageFee()
        {
            return View();
        }

        public IActionResult InventoryItem()
        {
            return View();
        }

        public IActionResult PurchaseEntry()
        {
            return View();
        }
    }
}
