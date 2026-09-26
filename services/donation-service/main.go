package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sqs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/joho/godotenv"
	"github.com/newrelic/go-agent/v3/integrations/nrawssdk-v1"
	"github.com/newrelic/go-agent/v3/integrations/nrpgx5" // tracer do pgx v5: spans de banco no trace distribuído
	"github.com/newrelic/go-agent/v3/newrelic"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type Donation struct {
	ID        int       `json:"id"`
	NgoID     int       `json:"ngo_id"`
	Amount    float64   `json:"amount"`
	DonorName string    `json:"donor_name"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

// sqsSendTimeout limita o envio síncrono ao SQS. Cobre a 1ª chamada (credenciais via IMDS) e os retries
// do SDK, sem deixar o POST pendurado se a fila estiver fora: a falha só é logada e a doação responde 201.
const sqsSendTimeout = 2 * time.Second

type App struct {
	DB          *sql.DB
	SqsSvc      *sqs.SQS
	SqsQueueURL string
	NR          *newrelic.Application // nil quando NEW_RELIC_LICENSE_KEY não está definida
}

func main() {
	_ = godotenv.Load()

	port := os.Getenv("PORT")
	if port == "" {
		port = "8082"
	}

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		log.Fatal("DATABASE_URL é obrigatória")
	}

	// APM New Relic: configurado 100% por variáveis de ambiente (NEW_RELIC_LICENSE_KEY, NEW_RELIC_APP_NAME,
	// NEW_RELIC_DISTRIBUTED_TRACING_ENABLED). Sem licença, nrApp fica nil e todas as chamadas viram no-op.
	nrApp, nrErr := newrelic.NewApplication(newrelic.ConfigFromEnvironment())
	if nrErr != nil {
		log.Printf("New Relic desabilitado: %v", nrErr)
		nrApp = nil
	}

	// pgx v5 (o v4 do repositório original tinha CVEs) com tracer do New Relic.
	pgCfg, err := pgx.ParseConfig(dbURL)
	if err != nil {
		log.Fatalf("DATABASE_URL inválida: %v", err)
	}
	pgCfg.Tracer = nrpgx5.NewTracer()
	db := stdlib.OpenDB(*pgCfg)
	db.SetMaxOpenConns(10) // alinhado ao tamanho do pod (rightsizing) e ao max_connections do db.t3.micro
	if err := db.Ping(); err != nil {
		log.Fatalf("Erro ao conectar ao banco de dados: %v", err)
	}
	log.Println("Conectado ao PostgreSQL (donation-service).")

	var sqsSvc *sqs.SQS
	queueURL := os.Getenv("AWS_SQS_URL")
	region := os.Getenv("AWS_REGION")
	if queueURL != "" && region != "" {
		cfg := &aws.Config{Region: aws.String(region)}
		// AWS_ENDPOINT_URL permite apontar para o LocalStack em desenvolvimento local.
		// Em produção (EKS) a variável não é definida e o SDK usa o endpoint real da AWS.
		if ep := os.Getenv("AWS_ENDPOINT_URL"); ep != "" {
			cfg.Endpoint = aws.String(ep)
		}
		sess, _ := session.NewSession(cfg)
		nrawssdk.InstrumentHandlers(&sess.Handlers) // spans das chamadas SQS no trace distribuído
		sqsSvc = sqs.New(sess)
		log.Println("Integração com AWS SQS ativada.")
	}

	app := &App{DB: db, SqsSvc: sqsSvc, SqsQueueURL: queueURL, NR: nrApp}

	mux := http.NewServeMux()
	// newrelic.WrapHandleFunc cria uma transação por request (no-op se nrApp == nil);
	// instrument() registra as Golden Metrics para o Prometheus.
	mux.HandleFunc(newrelic.WrapHandleFunc(nrApp, "/health", instrument("/health", app.HealthHandler)))
	mux.HandleFunc(newrelic.WrapHandleFunc(nrApp, "/donations", instrument("/donations", app.DonationHandler)))
	mux.Handle("/metrics", promhttp.Handler())

	log.Printf("donation-service rodando na porta %s", port)
	// TLS termina no Load Balancer/Ingress do Kubernetes; dentro do cluster o tráfego é HTTP na VPC privada.
	log.Fatal(http.ListenAndServe(":"+port, mux)) // nosemgrep: go.lang.security.audit.net.use-tls.use-tls
}

func (a *App) HealthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"ok","service":"donation-service"}`))
}

func (a *App) DonationHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodPost {
		var d Donation
		if err := json.NewDecoder(r.Body).Decode(&d); err != nil {
			http.Error(w, `{"error":"Payload inválido"}`, http.StatusBadRequest)
			return
		}

		d.Status = "APPROVED" // Simulação de gateway de pagamento
		err := a.DB.QueryRowContext(r.Context(),
			"INSERT INTO donations (ngo_id, amount, donor_name, status) VALUES ($1, $2, $3, $4) RETURNING id, created_at",
			d.NgoID, d.Amount, d.DonorName, d.Status,
		).Scan(&d.ID, &d.CreatedAt)

		if err != nil {
			log.Printf("Erro ao salvar doação: %v", err)
			http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
			return
		}

		if a.SqsSvc != nil {
			// Envio síncrono, antes de responder: o WrapHandleFunc encerra a transação do New Relic no retorno
			// do handler e o agente descarta segmentos abertos depois disso. Numa goroutine o span SQS nunca
			// aparecia no trace. O custo é ~10-30 ms (SQS na mesma região), dentro do SLO de 250 ms.
			// WithoutCancel: a doação já foi gravada, então o evento sai mesmo se o cliente desconectar,
			// e a transação continua no contexto para o nrawssdk.
			ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), sqsSendTimeout)
			a.sendNotificationEvent(ctx, d)
			cancel()
		}

		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(d)
		return
	}

	if r.Method == http.MethodGet {
		rows, err := a.DB.QueryContext(r.Context(), "SELECT id, ngo_id, amount, donor_name, status, created_at FROM donations ORDER BY id DESC LIMIT 100")
		if err != nil {
			http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
			return
		}
		defer rows.Close()

		donations := []Donation{}
		for rows.Next() {
			var d Donation
			rows.Scan(&d.ID, &d.NgoID, &d.Amount, &d.DonorName, &d.Status, &d.CreatedAt)
			donations = append(donations, d)
		}

		json.NewEncoder(w).Encode(donations)
		return
	}

	http.Error(w, `{"error":"Método não permitido"}`, http.StatusMethodNotAllowed)
}

func (a *App) sendNotificationEvent(ctx context.Context, d Donation) {
	body, _ := json.Marshal(d)
	_, err := a.SqsSvc.SendMessageWithContext(ctx, &sqs.SendMessageInput{
		MessageBody: aws.String(string(body)),
		QueueUrl:    aws.String(a.SqsQueueURL),
	})
	if err != nil {
		log.Printf("Falha ao despachar evento SQS: %v", err)
	}
}