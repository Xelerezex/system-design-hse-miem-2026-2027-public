package domain

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestPriceForSoldCount(t *testing.T) {
	cases := []struct {
		sold int
		want int64
	}{
		{0, 500000}, {99, 500000}, {100, 550000}, {199, 550000},
		{200, 605000}, {300, 665500},
	}
	for _, tc := range cases {
		got, err := PriceForSoldCount(500000, 100, 10, tc.sold)
		if err != nil || got != tc.want {
			t.Errorf("sold=%d price=%d want=%d err=%v", tc.sold, got, tc.want, err)
		}
	}
	if price, err := PriceForSoldCount(105, 1, 10, 1); err != nil || price != 116 {
		t.Errorf("round half up price=%d, err=%v", price, err)
	}
	if _, err := PriceForSoldCount(0, 100, 10, 0); err == nil {
		t.Fatal("invalid base price accepted")
	}
}

func TestOrderSumsDifferentHoldPrices(t *testing.T) {
	now := time.Now()
	user, event := uuid.New(), uuid.New()
	holds := []Hold{NewHold(event, 1, user, now, time.Minute), NewHold(event, 2, user, now, time.Minute)}
	holds[0].PriceMinor = 500000
	holds[1].PriceMinor = 550000
	order, err := NewOrder(holds, user, "mixed-prices", now)
	if err != nil || order.AmountMinor != 1050000 {
		t.Fatalf("order=%+v err=%v", order, err)
	}
}
