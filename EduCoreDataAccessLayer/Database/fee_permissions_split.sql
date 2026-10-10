-- ============================================================================
-- Split fees.manage into the money actions a school wants to control separately.
--
--   fees.collect     take money (counter, registration fee, fee at admission)
--   fees.cancel      cancel a receipt
--   fees.refund      refund a deposit or the advance wallet
--   fees.concession  give a concession / discount while collecting
--
-- fees.manage stays (fee setup, day close). Until now it covered all of the
-- above, so every role that has fees.manage today is granted all four here:
-- nobody loses access, and a school can then take cancel/refund away from a
-- cashier role on the Roles page. School admins bypass permissions anyway.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

INSERT INTO config.permissions (permission_key, module_group, display_name, sort_order)
VALUES
    ('fees.collect',    'Finance', 'Fees & Collection — Collect money',          73),
    ('fees.cancel',     'Finance', 'Fees & Collection — Cancel receipts',        74),
    ('fees.refund',     'Finance', 'Fees & Collection — Refunds',                75),
    ('fees.concession', 'Finance', 'Fees & Collection — Concessions & discounts', 76)
ON CONFLICT (permission_key) DO NOTHING;

-- Copy every live fees.manage grant to the four new keys (once).
INSERT INTO config.role_permissions (tenant_id, school_id, role_id, permission_id, is_allowed, created_by, created_at)
SELECT rp.tenant_id, rp.school_id, rp.role_id, np.permission_id, rp.is_allowed, rp.created_by, CURRENT_TIMESTAMP
FROM config.role_permissions rp
JOIN config.permissions mp ON mp.permission_id = rp.permission_id AND mp.permission_key = 'fees.manage'
CROSS JOIN config.permissions np
WHERE np.permission_key IN ('fees.collect', 'fees.cancel', 'fees.refund', 'fees.concession')
  AND COALESCE(rp.is_deleted, FALSE) = FALSE
  AND NOT EXISTS (
        SELECT 1 FROM config.role_permissions x
        WHERE x.tenant_id IS NOT DISTINCT FROM rp.tenant_id
          AND x.school_id IS NOT DISTINCT FROM rp.school_id
          AND x.role_id = rp.role_id
          AND x.permission_id = np.permission_id
          AND COALESCE(x.is_deleted, FALSE) = FALSE);

-- ----------------------------------------------------------------------------
-- Inventory used to be gated on fees.view (2026-10-10 it moved to its own
-- inventory.view / inventory.manage keys). Keep everyone's access: a role with
-- fees.view gets inventory.view, a role with fees.manage gets inventory.manage.
-- ----------------------------------------------------------------------------
INSERT INTO config.role_permissions (tenant_id, school_id, role_id, permission_id, is_allowed, created_by, created_at)
SELECT rp.tenant_id, rp.school_id, rp.role_id, np.permission_id, rp.is_allowed, rp.created_by, CURRENT_TIMESTAMP
FROM config.role_permissions rp
JOIN config.permissions mp ON mp.permission_id = rp.permission_id
JOIN config.permissions np ON np.permission_key =
        CASE mp.permission_key WHEN 'fees.view' THEN 'inventory.view'
                               WHEN 'fees.manage' THEN 'inventory.manage' END
WHERE mp.permission_key IN ('fees.view', 'fees.manage')
  AND COALESCE(rp.is_deleted, FALSE) = FALSE
  AND NOT EXISTS (
        SELECT 1 FROM config.role_permissions x
        WHERE x.tenant_id IS NOT DISTINCT FROM rp.tenant_id
          AND x.school_id IS NOT DISTINCT FROM rp.school_id
          AND x.role_id = rp.role_id
          AND x.permission_id = np.permission_id
          AND COALESCE(x.is_deleted, FALSE) = FALSE);
