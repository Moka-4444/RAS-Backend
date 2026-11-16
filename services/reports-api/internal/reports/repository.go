package reports

import (
	"context"
	"fmt"
	"strings"

	"github.com/jmoiron/sqlx"
)

type Repository struct {
	db *sqlx.DB
}

func NewRepository(db *sqlx.DB) *Repository {
	return &Repository{db: db}
}

// ============================================================
// Audit Logs
// ============================================================
func (r *Repository) ListAuditLogs(ctx context.Context, f AuditFilter) ([]*AuditLog, error) {
	baseQuery := `SELECT id, actor_id, actor_role, action, entity_type, entity_id, reason, created_at FROM audit_logs`
	var conditions []string
	var args []interface{}
	argIndex := 1

	if f.Action != "" {
		conditions = append(conditions, fmt.Sprintf("action = $%d", argIndex))
		args = append(args, f.Action)
		argIndex++
	}
	if f.EntityType != "" {
		conditions = append(conditions, fmt.Sprintf("entity_type = $%d", argIndex))
		args = append(args, f.EntityType)
		argIndex++
	}

	if len(conditions) > 0 {
		baseQuery += " WHERE " + strings.Join(conditions, " AND ")
	}
	baseQuery += " ORDER BY created_at DESC"

	if f.Limit == 0 {
		f.Limit = 50
	}
	baseQuery += fmt.Sprintf(" LIMIT $%d OFFSET $%d", argIndex, argIndex+1)
	args = append(args, f.Limit, f.Offset)

	var logs []*AuditLog
	if err := r.db.SelectContext(ctx, &logs, baseQuery, args...); err != nil {
		return nil, fmt.Errorf("list audit logs: %w", err)
	}
	return logs, nil
}

// ============================================================
// Sales Report
// ============================================================
func (r *Repository) GetSalesReport(ctx context.Context, f ReportFilter) (*SalesReportResponse, error) {
	query := `SELECT 
		COALESCE(SUM(net_amount), 0) as total_revenue,
		COUNT(id) as total_orders,
		COALESCE(SUM(CASE WHEN channel = 'RESTAURANT' THEN net_amount ELSE 0 END), 0) as restaurant_sales,
		COALESCE(SUM(CASE WHEN channel = 'DELIVERY' THEN net_amount ELSE 0 END), 0) as delivery_sales
		FROM sales WHERE 1=1`

	var args []interface{}
	argIndex := 1

	if f.BranchID != "" {
		query += fmt.Sprintf(" AND branch_id = $%d", argIndex)
		args = append(args, f.BranchID)
		argIndex++
	}
	if f.From != "" {
		query += fmt.Sprintf(" AND created_at >= $%d", argIndex)
		args = append(args, f.From)
		argIndex++
	}
	if f.To != "" {
		query += fmt.Sprintf(" AND created_at <= $%d", argIndex)
		args = append(args, f.To)
		argIndex++
	}

	var result SalesReportResponse
	err := r.db.GetContext(ctx, &result, query, args...)
	if err != nil {
		return nil, fmt.Errorf("get sales report: %w", err)
	}

	if result.TotalOrders > 0 {
		result.AverageOrder = result.TotalRevenue / float64(result.TotalOrders)
	}
	return &result, nil
}

// ============================================================
// Inventory Report
// ============================================================
func (r *Repository) GetInventoryReport(ctx context.Context, f ReportFilter) (*InventoryReportResponse, error) {
	query := `SELECT 
		COUNT(DISTINCT i.good_id) as total_items,
		COALESCE(SUM(i.quantity * i.unit_cost), 0) as total_value,
		COUNT(CASE WHEN i.quantity < COALESCE(i.reorder_level, g.reorder_level) THEN 1 END) as low_stock_items
		FROM inventories i
		JOIN goods g ON i.good_id = g.id
		WHERE 1=1`

	var args []interface{}
	argIndex := 1

	if f.BranchID != "" {
		query += fmt.Sprintf(" AND i.branch_id = $%d", argIndex)
		args = append(args, f.BranchID)
	}

	var result InventoryReportResponse
	err := r.db.GetContext(ctx, &result, query, args...)
	if err != nil {
		return nil, fmt.Errorf("get inventory report: %w", err)
	}
	return &result, nil
}

// ============================================================
// Attendance Report
// ============================================================
func (r *Repository) GetAttendanceReport(ctx context.Context, f ReportFilter) (*AttendanceReportResponse, error) {
	// Count active employees in the requested branch and attendance window.
	empQuery := `SELECT COUNT(id) FROM employees WHERE active = TRUE`
	var empArgs []interface{}
	if f.BranchID != "" {
		empQuery += ` AND branch_id = $1`
		empArgs = append(empArgs, f.BranchID)
	}
	var totalEmp int
	if err := r.db.GetContext(ctx, &totalEmp, empQuery, empArgs...); err != nil {
		return nil, fmt.Errorf("get total employees: %w", err)
	}

	// 2. Present & Absent
	attQuery := `SELECT 
		COUNT(DISTINCT employee_id) as present
		FROM attendance_records WHERE 1=1`

	var args []interface{}
	argIndex := 1
	if f.BranchID != "" {
		attQuery += fmt.Sprintf(" AND branch_id = $%d", argIndex)
		args = append(args, f.BranchID)
		argIndex++
	}
	if f.From != "" {
		attQuery += fmt.Sprintf(" AND work_date >= $%d", argIndex)
		args = append(args, f.From)
		argIndex++
	}
	if f.To != "" {
		attQuery += fmt.Sprintf(" AND work_date <= $%d", argIndex)
		args = append(args, f.To)
	}

	var attResult struct {
		Present int `db:"present"`
	}
	if err := r.db.GetContext(ctx, &attResult, attQuery, args...); err != nil {
		return nil, fmt.Errorf("get attendance report: %w", err)
	}

	// 3. Total Overtime
	otQuery := `SELECT COALESCE(SUM(amount), 0) FROM overtime WHERE status = 'approved'`
	var otArgs []interface{}
	var otConditions []string
	if f.BranchID != "" {
		otConditions = append(otConditions, "branch_id = $1")
		otArgs = append(otArgs, f.BranchID)
	}
	if f.From != "" {
		otConditions = append(otConditions, fmt.Sprintf("work_date >= $%d", len(otArgs)+1))
		otArgs = append(otArgs, f.From)
	}
	if f.To != "" {
		otConditions = append(otConditions, fmt.Sprintf("work_date <= $%d", len(otArgs)+1))
		otArgs = append(otArgs, f.To)
	}
	if len(otConditions) > 0 {
		otQuery += " AND " + strings.Join(otConditions, " AND ")
	}
	var totalOvertime float64
	if err := r.db.GetContext(ctx, &totalOvertime, otQuery, otArgs...); err != nil {
		return nil, fmt.Errorf("get overtime: %w", err)
	}

	return &AttendanceReportResponse{
		TotalEmployees: totalEmp,
		Present:        attResult.Present,
		Absent:         max(totalEmp-attResult.Present, 0),
		TotalOvertime:  totalOvertime,
	}, nil
}

// ============================================================
// Approval Queue
// ============================================================
func (r *Repository) GetApprovalQueue(ctx context.Context, f ReportFilter) (*ApprovalQueueResponse, error) {
	// 1. Pending Menu Requests
	menuQuery := `SELECT COUNT(id) FROM menu_item_requests WHERE status = 'PENDING'`
	var menuArgs []interface{}
	if f.BranchID != "" {
		menuQuery += ` AND branch_id = $1`
		menuArgs = append(menuArgs, f.BranchID)
	}
	var pendingMenu int
	if err := r.db.GetContext(ctx, &pendingMenu, menuQuery, menuArgs...); err != nil {
		return nil, fmt.Errorf("get menu requests: %w", err)
	}

	// 2. Pending Supply Requests
	supplyQuery := `SELECT COUNT(id) FROM supply_requests WHERE status = 'PENDING'`
	var supplyArgs []interface{}
	if f.BranchID != "" {
		supplyQuery += ` AND branch_id = $1`
		supplyArgs = append(supplyArgs, f.BranchID)
	}
	var pendingSupply int
	if err := r.db.GetContext(ctx, &pendingSupply, supplyQuery, supplyArgs...); err != nil {
		return nil, fmt.Errorf("get supply requests: %w", err)
	}

	return &ApprovalQueueResponse{
		PendingMenuRequests:   pendingMenu,
		PendingSupplyRequests: pendingSupply,
	}, nil
}
