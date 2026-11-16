package reports

import (
	"context"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
)

type Handler struct {
	svc reportService
}

type reportService interface {
	GetAuditLogs(context.Context, AuditFilter) ([]*AuditLog, error)
	GetSalesReport(context.Context, ReportFilter) (*SalesReportResponse, error)
	GetInventoryReport(context.Context, ReportFilter) (*InventoryReportResponse, error)
	GetAttendanceReport(context.Context, ReportFilter) (*AttendanceReportResponse, error)
	GetApprovalQueue(context.Context, ReportFilter) (*ApprovalQueueResponse, error)
}

func NewHandler(svc reportService) *Handler {
	return &Handler{svc: svc}
}

func (h *Handler) RegisterRoutes(r *gin.RouterGroup) {
	reports := r.Group("/reports")
	{
		reports.GET("/audit", h.getAuditLogs)
		reports.GET("/sales", h.getSalesReport)
		reports.GET("/inventory", h.getInventoryReport)
		reports.GET("/attendance", h.getAttendanceReport)
		reports.GET("/approvals", h.getApprovalQueue)
	}
}

// @Summary      Get Audit Logs
// @Tags         Reports
// @Produce      json
// @Param        action query string false "Filter by action"
// @Param        entity_type query string false "Filter by entity type"
// @Param        limit query int false "Limit" default(50)
// @Param        offset query int false "Offset" default(0)
// @Success      200 {array} AuditLogResponse
// @Router       /reports/audit [get]
func (h *Handler) getAuditLogs(c *gin.Context) {
	if !requireRole(c, "CEO") {
		return
	}
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
	if limit < 1 {
		limit = 50
	}
	if limit > 500 {
		limit = 500
	}
	if offset < 0 {
		offset = 0
	}

	filter := AuditFilter{
		Action:     c.Query("action"),
		EntityType: c.Query("entity_type"),
		Limit:      limit,
		Offset:     offset,
	}

	logs, err := h.svc.GetAuditLogs(c.Request.Context(), filter)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	resp := make([]AuditLogResponse, 0, len(logs))
	for _, l := range logs {
		resp = append(resp, l.ToResponse())
	}
	c.JSON(http.StatusOK, resp)
}

// @Summary      Get Sales Report
// @Tags         Reports
// @Produce      json
// @Param        branch_id query string false "Filter by branch ID"
// @Param        from query string false "From date (YYYY-MM-DD)"
// @Param        to query string false "To date (YYYY-MM-DD)"
// @Success      200 {object} SalesReportResponse
// @Router       /reports/sales [get]
func (h *Handler) getSalesReport(c *gin.Context) {
	branchID, ok := authorizedBranch(c, "BRANCH_MANAGER")
	if !ok {
		return
	}
	filter := ReportFilter{
		BranchID: branchID,
		From:     c.Query("from"),
		To:       c.Query("to"),
	}
	resp, err := h.svc.GetSalesReport(c.Request.Context(), filter)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, resp)
}

// @Summary      Get Inventory Report
// @Tags         Reports
// @Produce      json
// @Param        branch_id query string false "Filter by branch ID"
// @Success      200 {object} InventoryReportResponse
// @Router       /reports/inventory [get]
func (h *Handler) getInventoryReport(c *gin.Context) {
	branchID, ok := authorizedBranch(c, "BRANCH_MANAGER", "SUPPLY_MANAGER")
	if !ok {
		return
	}
	filter := ReportFilter{BranchID: branchID}
	resp, err := h.svc.GetInventoryReport(c.Request.Context(), filter)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, resp)
}

// @Summary      Get Attendance Report
// @Tags         Reports
// @Produce      json
// @Param        from query string false "From date"
// @Param        to query string false "To date"
// @Success      200 {object} AttendanceReportResponse
// @Router       /reports/attendance [get]
func (h *Handler) getAttendanceReport(c *gin.Context) {
	branchID, ok := authorizedBranch(c, "BRANCH_MANAGER")
	if !ok {
		return
	}
	filter := ReportFilter{
		BranchID: branchID,
		From:     c.Query("from"),
		To:       c.Query("to"),
	}
	resp, err := h.svc.GetAttendanceReport(c.Request.Context(), filter)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, resp)
}

// @Summary      Get Approval Queue
// @Tags         Reports
// @Produce      json
// @Success      200 {object} ApprovalQueueResponse
// @Router       /reports/approvals [get]
func (h *Handler) getApprovalQueue(c *gin.Context) {
	branchID, ok := authorizedBranch(c, "SUPPLY_MANAGER")
	if !ok {
		return
	}
	resp, err := h.svc.GetApprovalQueue(c.Request.Context(), ReportFilter{BranchID: branchID})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, resp)
}
func requireRole(c *gin.Context, allowed ...string) bool {
	role := c.GetString("user_role")
	if role == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "authenticated user context is required"})
		return false
	}
	for _, candidate := range allowed {
		if role == "CEO" || role == candidate {
			return true
		}
	}
	c.JSON(http.StatusForbidden, gin.H{"error": "role is not allowed to access this report"})
	return false
}

func authorizedBranch(c *gin.Context, scopedRoles ...string) (string, bool) {
	if !requireRole(c, scopedRoles...) {
		return "", false
	}
	if c.GetString("user_role") == "CEO" {
		return c.Query("branch_id"), true
	}
	if c.GetString("user_role") == "SUPPLY_MANAGER" {
		return c.Query("branch_id"), true
	}
	branchID := c.GetString("branch_id")
	if branchID == "" {
		c.JSON(http.StatusForbidden, gin.H{"error": "branch assignment is required"})
		return "", false
	}
	return branchID, true
}
