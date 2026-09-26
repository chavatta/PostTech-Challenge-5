package main

import (
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sqs"
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

// Driver SQL mínimo: responde o INSERT ... RETURNING id, created_at sem precisar de Postgres no CI.
type fakeDriver struct{}
type fakeConn struct{}
type fakeStmt struct{}
type fakeRows struct{ done bool }

func (fakeDriver) Open(string) (driver.Conn, error) {
	return fakeConn{}, nil
}

func (fakeConn) Prepare(string) (driver.Stmt, error) {
	return fakeStmt{}, nil
}

func (fakeConn) Close() error {
	return nil
}

func (fakeConn) Begin() (driver.Tx, error) {
	return nil, errors.New("sem transações")
}

func (fakeStmt) Close() error {
	return nil
}

func (fakeStmt) NumInput() int {
	return -1
}

func (fakeStmt) Exec([]driver.Value) (driver.Result, error) {
	return nil, errors.New("não usado")
}

func (fakeStmt) Query([]driver.Value) (driver.Rows, error) {
	return &fakeRows{}, nil
}

func (*fakeRows) Columns() []string {
	return []string{"id", "created_at"}
}

func (*fakeRows) Close() error {
	return nil
}

func (r *fakeRows) Next(dest []driver.Value) error {
	if r.done {
		return io.EOF
	}
	r.done = true
	dest[0] = int64(1)
	dest[1] = time.Now()
	return nil
}

func init() { sql.Register("fakedb", fakeDriver{}) }

// O SendMessage precisa acontecer antes de o handler retornar: é o que mantém o span SQS dentro da
// transação do New Relic (o WrapHandleFunc encerra a transação no retorno e descarta segmentos tardios).
func TestDonationHandlerSendsSQSBeforeResponding(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusOK) // corpo vazio: o SDK loga erro na resposta; o teste só precisa da chamada
	}))
	defer srv.Close()

	sess := session.Must(session.NewSession(&aws.Config{
		Region:      aws.String("us-east-1"),
		Endpoint:    aws.String(srv.URL),
		Credentials: credentials.NewStaticCredentials("test", "test", ""),
		MaxRetries:  aws.Int(0),
	}))
	db, err := sql.Open("fakedb", "")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	app := &App{DB: db, SqsSvc: sqs.New(sess), SqsQueueURL: srv.URL + "/000000000000/donations"}
	req := httptest.NewRequest(http.MethodPost, "/donations",
		strings.NewReader(`{"ngo_id":1,"amount":10,"donor_name":"Ana"}`))
	rr := httptest.NewRecorder()
	app.DonationHandler(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("esperado 201, obtido %d: %s", rr.Code, rr.Body.String())
	}
	if hits.Load() == 0 {
		t.Fatal("SendMessage não aconteceu antes da resposta: o span SQS ficaria fora do trace")
	}
}
