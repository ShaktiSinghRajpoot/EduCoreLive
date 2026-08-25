namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    // Turns the uuid a URL carries back into the internal integer id.
    //
    // One service for every entity so the entity names and the tenant guard live in a
    // single place — four copies of this method would eventually drift apart.
    public interface IPublicIdService
    {
        // Entity names accepted by core.fn_public_id_to_id.
        const string Student = "student";
        const string Staff   = "staff";
        const string Tc      = "tc";

        // Returns 0 when the uuid is unknown OR belongs to another school — the caller
        // cannot tell the two apart, so this cannot be used to probe for real ids.
        Task<int> ResolveAsync(string entity, Guid publicId, int tenantId, int schoolId);
    }
}
