package reports

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
)

type Handler struct {
	svc *Service
}

func NewHandler(svc *Service) *Handler {
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
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))

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
	filter := ReportFilter{
		BranchID: c.Query("branch_id"),
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
	filter := ReportFilter{BranchID: c.Query("branch_id")}
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
	filter := ReportFilter{
		From: c.Query("from"),
		To:   c.Query("to"),
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
	resp, err := h.svc.GetApprovalQueue(c.Request.Context(), ReportFilter{})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, resp)
}
func getBranchID(c *gin.Context) string {
	// لو المستخدم CEO، ياخد الـ branch_id من الـ Query
	role := c.GetString("user_role")
	if role == "CEO" {
		return c.Query("branch_id")
	}
	// لو Branch Manager، ياخد الـ branch_id بتاعه من الـ Context
	return c.GetString("branch_id")
}
