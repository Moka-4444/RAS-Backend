package reports

import (
	"time"

	"github.com/google/uuid"
)

// AuditLog - سجل المراجعة
type AuditLog struct {
	ID         uuid.UUID  `db:"id" json:"id"`
	ActorID    uuid.UUID  `db:"actor_id" json:"actor_id"`
	ActorRole  string     `db:"actor_role" json:"actor_role"`
	Action     string     `db:"action" json:"action"`
	EntityType string     `db:"entity_type" json:"entity_type"`
	EntityID   uuid.UUID  `db:"entity_id" json:"entity_id"`
	Reason     *string    `db:"reason" json:"reason,omitempty"`
	CreatedAt  time.Time  `db:"created_at" json:"created_at"`
}