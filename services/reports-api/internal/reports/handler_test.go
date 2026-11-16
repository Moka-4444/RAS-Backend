package reports

import (
	"context"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

type stubReportService struct {
	salesFilter     ReportFilter
	inventoryFilter ReportFilter
}

func (s *stubReportService) GetAuditLogs(context.Context, AuditFilter) ([]*AuditLog, error) {
	return nil, nil
}
func (s *stubReportService) GetSalesReport(_ context.Context, f ReportFilter) (*SalesReportResponse, error) {
	s.salesFilter = f
	return &SalesReportResponse{}, nil
}
func (s *stubReportService) GetInventoryReport(_ context.Context, f ReportFilter) (*InventoryReportResponse, error) {
	s.inventoryFilter = f
	return &InventoryReportResponse{}, nil
}
func (s *stubReportService) GetAttendanceReport(context.Context, ReportFilter) (*AttendanceReportResponse, error) {
	return &AttendanceReportResponse{}, nil
}
func (s *stubReportService) GetApprovalQueue(context.Context, ReportFilter) (*ApprovalQueueResponse, error) {
	return &ApprovalQueueResponse{}, nil
}

func requestForRole(role, branch, path string) *httptest.ResponseRecorder {
	gin.SetMode(gin.TestMode)
	service := &stubReportService{}
	router := gin.New()
	router.Use(func(c *gin.Context) {
		c.Set("user_role", role)
		c.Set("branch_id", branch)
		c.Next()
	})
	NewHandler(service).RegisterRoutes(router.Group("/api/v1"))
	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest("GET", path, nil))
	return response
}

func TestSalesReportRequiresAuthenticatedRole(t *testing.T) {
	response := requestForRole("", "", "/api/v1/reports/sales")
	if response.Code != 401 {
		t.Fatalf("status = %d, want 401", response.Code)
	}
}

func TestBranchManagerCannotSelectAnotherBranch(t *testing.T) {
	gin.SetMode(gin.TestMode)
	service := &stubReportService{}
	router := gin.New()
	router.Use(func(c *gin.Context) {
		c.Set("user_role", "BRANCH_MANAGER")
		c.Set("branch_id", "assigned-branch")
		c.Next()
	})
	NewHandler(service).RegisterRoutes(router.Group("/api/v1"))
	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest("GET", "/api/v1/reports/sales?branch_id=other-branch", nil))
	if response.Code != 200 {
		t.Fatalf("status = %d, want 200", response.Code)
	}
	if service.salesFilter.BranchID != "assigned-branch" {
		t.Fatalf("branch filter = %q, want assigned branch", service.salesFilter.BranchID)
	}
}

func TestBranchManagerRequiresAssignedBranch(t *testing.T) {
	response := requestForRole("BRANCH_MANAGER", "", "/api/v1/reports/inventory")
	if response.Code != 403 {
		t.Fatalf("status = %d, want 403", response.Code)
	}
}

func TestOnlyCEOCanReadUnscopedAuditLogs(t *testing.T) {
	response := requestForRole("BRANCH_MANAGER", "assigned-branch", "/api/v1/reports/audit")
	if response.Code != 403 {
		t.Fatalf("status = %d, want 403", response.Code)
	}
}
