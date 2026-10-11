namespace educore.Models
{
    public class DropdownItem
    {
        public int Id { get; set; }
        public string Name { get; set; } = "";

        /// <summary>
        /// Boards, school types and ownership types only: comma list of the institution
        /// categories the row is offered for ("SCHOOL", "COMPUTER_IT,COACHING"). Empty =
        /// every category. The Create School wizard filters its lists on it.
        /// </summary>
        public string Categories { get; set; } = "";
    }
}
