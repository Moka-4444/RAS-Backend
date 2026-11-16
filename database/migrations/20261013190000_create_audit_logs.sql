-- +goose Up
CREATE TABLE IF NOT EXISTS audit_logs (
    id          UUID PRIMARY KEY,
    actor_id    UUID NOT NULL,
    actor_role  TEXT NOT NULL,
    action      TEXT NOT NULL, -- 'APPROVE', 'REJECT', 'ADJUST', 'CANCEL_DISCOUNT', 'CLOSE_SHIFT', 'PRICE_CHANGE'
    entity_type TEXT NOT NULL, -- 'MENU_ITEM', 'INVENTORY', 'SHIFT', 'DISCOUNT'
    entity_id   UUID NOT NULL,
    old_value   JSONB,
    new_value   JSONB,
    reason      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_actor ON audit_logs (actor_id);
CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_logs (entity_type, entity_id);

-- +goose StatementBegin
DO $$ BEGIN
    -- Reports App (بتقرأ وتكتب)
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reports_app') THEN
        EXECUTE 'GRANT INSERT, SELECT ON audit_logs TO reports_app';
    END IF;
    
    -- Sales App (بتكتب)
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sales_app') THEN
        EXECUTE 'GRANT INSERT ON audit_logs TO sales_app';
    END IF;
    
    -- Menu App (بتكتب)
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'menu_app') THEN
        EXECUTE 'GRANT INSERT ON audit_logs TO menu_app';
    END IF;
    
    -- Inventory App (بتكتب)
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'inventory_app') THEN
        EXECUTE 'GRANT INSERT ON audit_logs TO inventory_app';
    END IF;
    
    -- Central Kitchen App (بتكتب)
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'central_kitchen_app') THEN
        EXECUTE 'GRANT INSERT ON audit_logs TO central_kitchen_app';
    END IF;
END $$;
-- +goose StatementEnd

-- +goose Down
DROP TABLE audit_logs;