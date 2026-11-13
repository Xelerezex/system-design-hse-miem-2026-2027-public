package domain

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/nikolaysavelev/soldout/internal/booking/api"
)

func holdsFor(user, event uuid.UUID, now time.Time, n int) []Hold {
	out := make([]Hold, 0, n)
	for i := 0; i < n; i++ {
		h := NewHold(event, int64(i+1), user, now, 10*time.Minute)
		h.PriceMinor = 500000
		out = append(out, h)
	}
	return out
}

func TestNewOrder_OK(t *testing.T) {
	now := time.Now()
	user, event := uuid.New(), uuid.New()
	o, err := NewOrder(holdsFor(user, event, now, 2), user, "key-1", now)
	if err != nil {
		t.Fatalf("ожидался успех: %v", err)
	}
	if o.Status != api.OrderPending || o.AmountMinor != 1000000 || o.AmountString() != "10000.00" || len(o.SeatIDs) != 2 {
		t.Fatalf("неверный заказ: %+v", o)
	}
}

func TestNewOrder_Rules(t *testing.T) {
	now := time.Now()
	user, event := uuid.New(), uuid.New()

	if _, err := NewOrder(nil, user, "k", now); !errors.Is(err, api.ErrValidation) {
		t.Errorf("пустой заказ: %v", err)
	}
	if _, err := NewOrder(holdsFor(user, event, now, 5), user, "k", now); !errors.Is(err, api.ErrHoldLimit) {
		t.Errorf("5 hold'ов: %v", err)
	}
	if _, err := NewOrder(holdsFor(user, event, now, 1), user, "", now); !errors.Is(err, api.ErrValidation) {
		t.Errorf("пустой ключ: %v", err)
	}
	if _, err := NewOrder(holdsFor(uuid.New(), event, now, 1), user, "k", now); !errors.Is(err, api.ErrHoldsMismatch) {
		t.Errorf("чужой hold: %v", err)
	}
	mixed := append(holdsFor(user, event, now, 1), holdsFor(user, uuid.New(), now, 1)...)
	if _, err := NewOrder(mixed, user, "k", now); !errors.Is(err, api.ErrHoldsMismatch) {
		t.Errorf("разные мероприятия: %v", err)
	}
	released := holdsFor(user, event, now, 1)
	_ = released[0].Release()
	if _, err := NewOrder(released, user, "k", now); !errors.Is(err, api.ErrHoldNotActive) {
		t.Errorf("released hold: %v", err)
	}
	if _, err := NewOrder(holdsFor(user, event, now, 1), user, "k", now.Add(time.Hour)); !errors.Is(err, api.ErrHoldExpired) {
		t.Errorf("истёкший hold: %v", err)
	}
	dup := holdsFor(user, event, now, 1)
	dup = append(dup, dup[0])
	if _, err := NewOrder(dup, user, "k", now); !errors.Is(err, api.ErrValidation) {
		t.Errorf("дубликат hold: %v", err)
	}
}

func TestOrder_Transitions(t *testing.T) {
	now := time.Now()
	user, event := uuid.New(), uuid.New()
	o, _ := NewOrder(holdsFor(user, event, now, 1), user, "k", now)
	if err := o.MarkPaid(now); err != nil || o.Status != api.OrderPaid {
		t.Fatalf("pending → paid: %v", err)
	}
	if err := o.MarkFailed(now); !errors.Is(err, api.ErrOrderNotPending) {
		t.Fatalf("paid → failed запрещён: %v", err)
	}
	if err := o.MarkExpired(now); !errors.Is(err, api.ErrOrderNotPending) {
		t.Fatalf("paid → expired запрещён: %v", err)
	}
}

func TestFormatMinor(t *testing.T) {
	for minor, want := range map[int64]string{0: "0.00", 5: "0.05", 500000: "5000.00", 123456: "1234.56"} {
		if got := FormatMinor(minor); got != want {
			t.Errorf("FormatMinor(%d) = %q, ожидалось %q", minor, got, want)
		}
	}
}
