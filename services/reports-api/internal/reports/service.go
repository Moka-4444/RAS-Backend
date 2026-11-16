package reports

import "context"

type Service struct {
	repo *Repository
}

func NewService(repo *Repository) *Service {
	return &Service{repo: repo}
}

func (s *Service) GetAuditLogs(ctx context.Context, f AuditFilter) ([]*AuditLog, error) {
	return s.repo.ListAuditLogs(ctx, f)
}

func (s *Service) GetSalesReport(ctx context.Context, f ReportFilter) (*SalesReportResponse, error) {
	return s.repo.GetSalesReport(ctx, f)
}

func (s *Service) GetInventoryReport(ctx context.Context, f ReportFilter) (*InventoryReportResponse, error) {
	return s.repo.GetInventoryReport(ctx, f)
}

func (s *Service) GetAttendanceReport(ctx context.Context, f ReportFilter) (*AttendanceReportResponse, error) {
	return s.repo.GetAttendanceReport(ctx, f)
}

func (s *Service) GetApprovalQueue(ctx context.Context, f ReportFilter) (*ApprovalQueueResponse, error) {
	return s.repo.GetApprovalQueue(ctx, f)
}
