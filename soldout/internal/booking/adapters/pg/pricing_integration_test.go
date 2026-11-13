package pg_test

import (
	"context"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/testcontainers/testcontainers-go"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"

	bookingpg "github.com/nikolaysavelev/soldout/internal/booking/adapters/pg"
	"github.com/nikolaysavelev/soldout/internal/booking/api"
	"github.com/nikolaysavelev/soldout/internal/booking/app"
	"github.com/nikolaysavelev/soldout/internal/platform/db"
)

func TestDynamicPriceAcrossPaidBoundary(t *testing.T) {
	if testing.Short() {
		t.Skip("integration test requires Docker")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	pgc, err := tcpostgres.Run(ctx, "postgres:17-alpine",
		tcpostgres.WithDatabase("soldout"), tcpostgres.WithUsername("soldout"), tcpostgres.WithPassword("soldout"),
		testcontainers.WithWaitStrategy(wait.ForLog("database system is ready to accept connections").WithOccurrence(2).WithStartupTimeout(60*time.Second)),
	)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = pgc.Terminate(context.Background()) })
	url, err := pgc.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Migrate(ctx, url, slog.Default()); err != nil {
		t.Fatal(err)
	}
	pool, err := db.NewPool(ctx, url, db.PoolOptions{MaxConns: 20}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if err := db.Seed(ctx, pool, 3000, nil); err != nil {
		t.Fatal(err)
	}

	eventID := uuid.MustParse("10000000-0000-4000-8000-000000000001")
	venueID := uuid.MustParse("20000000-0000-4000-8000-000000000001")
	sectorID := uuid.MustParse("30000000-0000-4000-8000-0000000003e9")
	// Create 99 already confirmed seats within sector 1; prices for these historical
	// data are not involved in deciding the next tier.
	_, err = pool.Exec(ctx, `INSERT INTO holds
        (id, event_id, seat_id, sector_id, user_id, status, expires_at, price_minor, sold_count_at_hold)
        SELECT gen_random_uuid(), $1, n, $2, gen_random_uuid(), 'confirmed', now() + interval '1 hour', 100, 0
        FROM generate_series(10,108) AS n`, eventID, sectorID)
	if err != nil {
		t.Fatal(err)
	}
	// Direct fixture inserts bypass PayOrder, so seed the materialized counter as well.
	_, err = pool.Exec(ctx, `INSERT INTO booking_sector_sales (event_id, sector_id, sold_count)
		SELECT event_id, sector_id, count(*) FROM holds
		WHERE event_id = $1 AND sector_id = $2 AND status = 'confirmed'
		GROUP BY event_id, sector_id`, eventID, sectorID)
	if err != nil {
		t.Fatal(err)
	}

	svc := app.New(bookingpg.New(pool), fakeCatalog{eventID: eventID, venueID: venueID}, fakeQueue{}, fakePayment{}, fakeTickets{},
		app.Options{HoldTTL: time.Minute}, slog.Default())
	userA, userB := uuid.New(), uuid.New()
	var wg sync.WaitGroup
	wg.Add(2)
	var a, b api.Hold
	var errA, errB error
	go func() {
		defer wg.Done()
		a, errA = svc.CreateHold(ctx, api.CreateHoldInput{EventID: eventID, SeatID: 1, UserID: userA, AdmissionToken: "ok"})
	}()
	go func() {
		defer wg.Done()
		b, errB = svc.CreateHold(ctx, api.CreateHoldInput{EventID: eventID, SeatID: 2, UserID: userB, AdmissionToken: "ok"})
	}()
	wg.Wait()
	if errA != nil || errB != nil {
		t.Fatalf("create holds: %v, %v", errA, errB)
	}
	if a.PriceMinor != 100 || b.PriceMinor != 100 || a.SoldCountAtHold != 99 || b.SoldCountAtHold != 99 {
		t.Fatalf("wrong initial tier: a=%+v b=%+v", a, b)
	}

	first, created, err := svc.CreateOrder(ctx, api.CreateOrderInput{HoldIDs: []uuid.UUID{a.ID}, UserID: userA, IdempotencyKey: "price-1"})
	if err != nil || !created || first.AmountMinor != 100 {
		t.Fatalf("first order: %+v %v", first, err)
	}
	paid, err := svc.PayOrder(ctx, api.PayOrderInput{OrderID: first.ID})
	if err != nil || paid.Status != api.OrderPaid {
		t.Fatalf("pay first: %+v %v", paid, err)
	}

	third, err := svc.CreateHold(ctx, api.CreateHoldInput{EventID: eventID, SeatID: 3, UserID: uuid.New(), AdmissionToken: "ok"})
	if err != nil {
		t.Fatal(err)
	}
	if third.PriceMinor != 110 || third.SoldCountAtHold != 100 {
		t.Fatalf("wrong new tier: %+v", third)
	}
	storedB, err := svc.GetHold(ctx, b.ID)
	if err != nil || storedB.PriceMinor != 100 {
		t.Fatalf("old price changed: %+v %v", storedB, err)
	}
	second, _, err := svc.CreateOrder(ctx, api.CreateOrderInput{HoldIDs: []uuid.UUID{b.ID}, UserID: userB, IdempotencyKey: "price-2"})
	if err != nil || second.AmountMinor != 100 {
		t.Fatalf("old order repriced: %+v %v", second, err)
	}
	if _, err := svc.PayOrder(ctx, api.PayOrderInput{OrderID: first.ID}); err != nil {
		t.Fatalf("repeat pay: %v", err)
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM holds WHERE event_id=$1 AND sector_id=$2 AND status='confirmed'`, eventID, sectorID).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 100 {
		t.Fatalf("idempotent pay altered sold_count: %d", n)
	}
	var counter int
	if err := pool.QueryRow(ctx, `SELECT sold_count FROM booking_sector_sales WHERE event_id = $1 AND sector_id = $2`, eventID, sectorID).Scan(&counter); err != nil {
		t.Fatal(err)
	}
	if counter != n {
		t.Fatalf("counter after repeated pay = %d, actual confirmed = %d", counter, n)
	}
	// An order with two seats increments exactly twice, not twice on a payment retry.
	multiUser := uuid.New()
	h4, err := svc.CreateHold(ctx, api.CreateHoldInput{EventID: eventID, SeatID: 4, UserID: multiUser, AdmissionToken: "ok"})
	if err != nil {
		t.Fatal(err)
	}
	h5, err := svc.CreateHold(ctx, api.CreateHoldInput{EventID: eventID, SeatID: 5, UserID: multiUser, AdmissionToken: "ok"})
	if err != nil {
		t.Fatal(err)
	}
	multiOrder, _, err := svc.CreateOrder(ctx, api.CreateOrderInput{HoldIDs: []uuid.UUID{h4.ID, h5.ID}, UserID: multiUser, IdempotencyKey: "price-multi"})
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if _, err := svc.PayOrder(ctx, api.PayOrderInput{OrderID: multiOrder.ID}); err != nil {
			t.Fatalf("pay multi-seat attempt %d: %v", i, err)
		}
	}
	if err := pool.QueryRow(ctx, `SELECT sold_count FROM booking_sector_sales WHERE event_id = $1 AND sector_id = $2`, eventID, sectorID).Scan(&counter); err != nil {
		t.Fatal(err)
	}
	if counter != 102 {
		t.Fatalf("multi-seat pay and retry: got %d, want 102", counter)
	}
}
