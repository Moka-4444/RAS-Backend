package menu

import (
	"context"
	"errors"
	"testing"
)

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
