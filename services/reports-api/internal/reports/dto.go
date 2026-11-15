package reports

import "time"

// ============================================================
// Audit Log
// ============================================================
type AuditLogResponse struct {
	ID         string  `json:"id"`
	ActorID    string  `json:"actor_id"`
	ActorRole  string  `json:"actor_role"`
	Action     string  `json:"action"`
	EntityType string  `json:"entity_type"`
	EntityID   string  `json:"entity_id"`
	Reason     *string `json:"reason,omitempty"`
	CreatedAt  string  `json:"created_at"`
}

func (a *AuditLog) ToResponse() AuditLogResponse {
	return AuditLogResponse{
		ID: a.ID.String(), ActorID: a.ActorID.String(), ActorRole: a.ActorRole,
		Action: a.Action, EntityType: a.EntityType, EntityID: a.EntityID.String(),
		Reason: a.Reason, CreatedAt: a.CreatedAt.Format(time.RFC3339),
	}
}

type AuditFilter struct {
	Action     string
	EntityType string
	Limit      int
	Offset     int
}

// ============================================================
// Sales Report
// ============================================================
type SalesReportResponse struct {
	TotalRevenue    float64 `db:"total_revenue" json:"total_revenue"`
	TotalOrders     int     `db:"total_orders" json:"total_orders"`
	AverageOrder    float64 `db:"average_order" json:"average_order"`
	RestaurantSales float64 `db:"restaurant_sales" json:"restaurant_sales"`
	DeliverySales   float64 `db:"delivery_sales" json:"delivery_sales"`
}

// ============================================================
// Inventory Report
// ============================================================
type InventoryReportResponse struct {
	TotalItems    int     `db:"total_items" json:"total_items"`
	TotalValue    float64 `db:"total_value" json:"total_value"`
	LowStockItems int     `db:"low_stock_items" json:"low_stock_items"`
}

// ============================================================
// Attendance Report
// ============================================================
type AttendanceReportResponse struct {
	TotalEmployees int     `db:"total_employees" json:"total_employees"`
	Present        int     `db:"present" json:"present"`
	Absent         int     `db:"absent" json:"absent"`
	TotalOvertime  float64 `db:"total_overtime" json:"total_overtime"`
}

// ============================================================
// Approval Queue
// ============================================================
type ApprovalQueueResponse struct {
	PendingMenuRequests   int `db:"pending_menu_requests" json:"pending_menu_requests"`
	PendingSupplyRequests int `db:"pending_supply_requests" json:"pending_supply_requests"`
}

// ============================================================
// Request Filters
// ============================================================
type ReportFilter struct {
	BranchID string
	From     string
	To       string
}
