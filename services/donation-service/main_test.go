package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthHandler(t *testing.T) {
	app := &App{}
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rr := httptest.NewRecorder()
	app.HealthHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("esperado 200, obtido %d", rr.Code)
	}
	if !strings.Contains(rr.Body.String(), `"service":"donation-service"`) {
		t.Fatalf("body inesperado: %s", rr.Body.String())
	}
}

func TestDonationHandlerRejectsInvalidPayload(t *testing.T) {
	app := &App{}
	req := httptest.NewRequest(http.MethodPost, "/donations", strings.NewReader("{nao-e-json"))
	rr := httptest.NewRecorder()
	app.DonationHandler(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("esperado 400, obtido %d", rr.Code)
	}
}

func TestDonationHandlerMethodNotAllowed(t *testing.T) {
	app := &App{}
	req := httptest.NewRequest(http.MethodDelete, "/donations", nil)
	rr := httptest.NewRecorder()
	app.DonationHandler(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("esperado 405, obtido %d", rr.Code)
	}
}
