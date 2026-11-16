package menu

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestMenuRequestRequiresManagerAssignedToBranch(t *testing.T) {
	const actor = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	const branch = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	const otherBranch = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
	router := gin.New()
	router.Use(func(c *gin.Context) {
		c.Set(CtxUserID, actor)
		c.Set(CtxUserRole, "BRANCH_MANAGER")
		c.Set(CtxBranchID, branch)
	})
	NewHandler(NewService(nil, nil)).RegisterRoutes(router.Group("/api/v1"))
	request := httptest.NewRequest(http.MethodPost, "/api/v1/menu/requests",
		strings.NewReader(`{"branch_id":"`+otherBranch+`","item_name":"Test item","requested_price":12}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403; body=%s", response.Code, response.Body.String())
	}
}

func TestApproveRequestRequiresCEOActor(t *testing.T) {
	service := NewService(nil, nil)
	_, err := service.ApproveRequest(context.Background(), ApproveRequestInput{
		RequestID: "request-id", ActorID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", ActorRole: "BRANCH_MANAGER",
	})
	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("ApproveRequest() error = %v, want ErrUnauthorized", err)
	}
}

func TestApproveRequestRequiresAuthenticatedActorID(t *testing.T) {
	service := NewService(nil, nil)
	_, err := service.ApproveRequest(context.Background(), ApproveRequestInput{
		RequestID: "request-id", ActorRole: "CEO",
	})
	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("ApproveRequest() error = %v, want ErrUnauthorized before database access", err)
	}
}
